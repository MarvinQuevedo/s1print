import Foundation
import CoreBluetooth
import Combine

enum BLEUARTProfile: CaseIterable {
    case ff00, uart18f0

    var serviceUUID: CBUUID { CBUUID(string: self == .ff00 ? "FF00" : "18F0") }
    var writeUUID: CBUUID { CBUUID(string: self == .ff00 ? "FF02" : "2AF1") }
    var notifyUUID: CBUUID { CBUUID(string: self == .ff00 ? "FF01" : "2AF0") }
    /// Second notify characteristic some firmware also answers on (FF03 next to FF01).
    var auxNotifyUUID: CBUUID? { self == .ff00 ? CBUUID(string: "FF03") : nil }

    static func matching(_ uuid: CBUUID) -> BLEUARTProfile? {
        // CoreBluetooth can report Bluetooth base UUIDs in either short or full form.
        allCases.first { $0.serviceUUID == uuid }
    }
}

/// BLE UART transport. Uses the Rust protocol bytes unchanged, with negotiated GATT write sizes.
@MainActor final class BluetoothPrinter: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate, PrintChannel {
    @Published var devices: [CBPeripheral] = []
    @Published var message = "Scan for your S1 printer."
    @Published var busy = false
    @Published var scanning = false
    @Published private(set) var selectedDevice: CBPeripheral?
    private let settings: PrintSettings
    private var discoveryRequested = false
    var isBluetoothReady: Bool { central.state == .poweredOn }
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var auxNotifyCharacteristic: CBCharacteristic?
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var writeWaiter: CheckedContinuation<Void, Error>?
    private var flowWaiter: CheckedContinuation<Void, Error>?
    private var flowTimer: Task<Void, Never>?
    private var replyWaiter: CheckedContinuation<Data, Error>?
    private var replyPredicate: ((Data) -> Bool)?
    private var received = Data()
    private var deadline: Task<Void, Never>?
    private var scanDeadline: Task<Void, Never>?
    private var disconnecting = false
    private var window = SendWindow()
    private var strategy = SendStrategy.defaultStrategy
    /// Replies are cleared after the next gate opens too, so notifications that were still in flight cannot leak in.
    private var discardPending = false
    private var jobStart: TimeInterval = 0
    private var jobBytes = 0

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // Keep transport metadata only; never persist document or raster bytes.
    private func trace(_ event: String) { BLETrace.log(event) }

    private func connectionStage(_ stage: String) {
        message = stage
        trace(stage)
        arm(15, message: "\(stage) timed out. No print data was sent.")
    }

    override convenience init() { self.init(settings: PrintSettings()) }
    init(settings: PrintSettings) {
        self.settings = settings
        super.init()
        trace("Transport initialized; strategy=\(settings.sendStrategy.rawValue)")
        central = CBCentralManager(delegate: self, queue: .main)
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            message = "Bluetooth is ready. Scan for your S1."
            if discoveryRequested { scan() }
        case .unauthorized: message = "Allow Bluetooth access in Settings."
        case .poweredOff: message = "Turn on Bluetooth to print."
        case .unsupported: message = "Bluetooth is unavailable on this device."
        default: message = "Bluetooth is not ready."
        }
        if central.state != .poweredOn { fail(PrintFailure(message)); scanning = false }
    }
    func startDiscovery() {
        discoveryRequested = true
        if central.state == .poweredOn, !scanning { scan() }
    }
    func select(_ device: CBPeripheral) {
        selectedDevice = device
        settings.select(id: device.identifier, name: device.name ?? "S1 printer")
    }
    func forgetSelection() {
        selectedDevice = nil
        settings.forgetPrinter()
    }
    func scan() {
        guard central.state == .poweredOn, !busy else { return }
        discoveryRequested = true
        selectedDevice = nil; devices = []; scanning = true
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        message = "Looking for nearby BLE printers…"
        scanDeadline?.cancel()
        scanDeadline = Task { try? await Task.sleep(for: .seconds(12)); if !Task.isCancelled { stopScan() } }
    }
    func stopScan() { central.stopScan(); scanDeadline?.cancel(); scanning = false; discoveryRequested = false }
    func disconnectIfIdle() {
        guard !busy else { return }
        stopScan()
        if peripheral != nil { fail(PrintFailure("Bluetooth connection closed")) }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "").lowercased()
        guard name.contains("pps1") || name.contains("s1_") || name.contains("luck") else { return }
        if !devices.contains(where: { $0.identifier == peripheral.identifier }) { devices.append(peripheral) }
        if selectedDevice == nil, settings.savedPrinter?.id == peripheral.identifier { selectedDevice = peripheral }
    }
    func cancel() { fail(PrintFailure("Canceled. Check the printed paper before retrying.")) }
    private func arm(_ seconds: Double, message: String) {
        deadline?.cancel()
        deadline = Task {
            try? await Task.sleep(for: .seconds(seconds))
            if !Task.isCancelled { fail(PrintFailure(message)) }
        }
    }
    private func fail(_ error: Error) {
        trace("Failure: \(error.localizedDescription)")
        deadline?.cancel()
        let connect = connectWaiter; connectWaiter = nil
        let write = writeWaiter; writeWaiter = nil
        flowTimer?.cancel(); flowTimer = nil
        let flow = flowWaiter; flowWaiter = nil
        let reply = replyWaiter; replyWaiter = nil; replyPredicate = nil
        connect?.resume(throwing: error); write?.resume(throwing: error)
        flow?.resume(throwing: error); reply?.resume(throwing: error)
        writeCharacteristic = nil; notifyCharacteristic = nil; auxNotifyCharacteristic = nil
        if let peripheral, peripheral.state != .disconnected {
            disconnecting = true; central.cancelPeripheralConnection(peripheral)
        } else {
            peripheral = nil; disconnecting = false
        }
    }
    private func connect(_ device: CBPeripheral) async throws {
        guard central.state == .poweredOn else { throw PrintFailure("Turn on Bluetooth and allow S1Print access") }
        guard !disconnecting else { throw PrintFailure("The previous connection is closing. Try again shortly.") }
        if peripheral === device, device.state == .connected, writeCharacteristic != nil, notifyCharacteristic != nil { return }
        if let previous = peripheral, previous.state != .disconnected {
            central.cancelPeripheralConnection(previous)
            throw PrintFailure("The previous printer is disconnecting. Try again shortly.")
        }
        peripheral = device; device.delegate = self
        writeCharacteristic = nil; notifyCharacteristic = nil; auxNotifyCharacteristic = nil
        stopScan()
        try await withCheckedThrowingContinuation { continuation in
            connectWaiter = continuation
            connectionStage("Connecting to printer")
            central.connect(device)
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral === peripheral else { return }
        connectionStage("Discovering printer services")
        peripheral.discoverServices(nil)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        self.peripheral = nil; disconnecting = false
        fail(error ?? PrintFailure("Cannot connect to printer"))
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else { return }
        trace("Disconnected: \(error?.localizedDescription ?? "no system error")")
        self.peripheral = nil; disconnecting = false
        fail(error ?? PrintFailure("Printer disconnected. Check the paper before retrying."))
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral, connectWaiter != nil else { return }
        if let error { fail(error); return }
        trace("Services: \((peripheral.services ?? []).map { $0.uuid.uuidString }.joined(separator: ", "))")
        guard let service = BLEUARTProfile.allCases.compactMap({ profile in
            peripheral.services?.first { $0.uuid == profile.serviceUUID }
        }).first else {
            fail(PrintFailure("This printer exposes no supported BLE UART service")); return
        }
        connectionStage("Discovering printer characteristics")
        peripheral.discoverCharacteristics(nil, for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral, connectWaiter != nil else { return }
        if let error { fail(error); return }
        let characteristics = service.characteristics ?? []
        trace("Characteristics for \(service.uuid.uuidString): \(characteristics.map { "\($0.uuid.uuidString) properties=\($0.properties.rawValue)" }.joined(separator: ", "))")
        guard let profile = BLEUARTProfile.matching(service.uuid) else {
            fail(PrintFailure("Unsupported BLE service: \(service.uuid.uuidString)")); return
        }
        guard let write = characteristics.first(where: { $0.uuid == profile.writeUUID && (!$0.properties.intersection([.write, .writeWithoutResponse]).isEmpty) }),
              let notify = characteristics.first(where: { $0.uuid == profile.notifyUUID && (!$0.properties.intersection([.notify, .indicate]).isEmpty) }) else {
            fail(PrintFailure("Unsupported BLE write/notification characteristics")); return
        }
        writeCharacteristic = write; notifyCharacteristic = notify
        auxNotifyCharacteristic = profile.auxNotifyUUID.flatMap { uuid in
            characteristics.first { $0.uuid == uuid && !$0.properties.intersection([.notify, .indicate]).isEmpty }
        }
        connectionStage("Enabling printer notifications")
        peripheral.setNotifyValue(true, for: notify)
        if let aux = auxNotifyCharacteristic { peripheral.setNotifyValue(true, for: aux) }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral else { return }
        if characteristic === auxNotifyCharacteristic {
            // The second channel is optional: log it, never fail the connection over it.
            trace("Notifications \(characteristic.uuid.uuidString) enabled=\(characteristic.isNotifying) error=\(error?.localizedDescription ?? "none")")
            return
        }
        guard connectWaiter != nil else { return }
        if let error { fail(error); return }
        guard characteristic === notifyCharacteristic, characteristic.isNotifying else { return }
        trace("Notifications enabled; printer transport ready")
        trace("Max write length: withResponse=\(peripheral.maximumWriteValueLength(for: .withResponse)) withoutResponse=\(peripheral.maximumWriteValueLength(for: .withoutResponse)); write properties=\(writeCharacteristic?.properties.rawValue ?? 0)")
        deadline?.cancel(); let waiter = connectWaiter; connectWaiter = nil; waiter?.resume()
    }
    func send(_ data: Data) async throws {
        guard let peripheral, let characteristic = writeCharacteristic, peripheral.state == .connected else { throw PrintFailure("Printer is disconnected") }
        let properties = characteristic.properties
        let type: CBCharacteristicWriteType
        switch strategy {
        case .ackedPaced, .acked:
            type = properties.contains(.write) ? .withResponse : .withoutResponse
        case .windowed, .flow:
            if properties.contains(.writeWithoutResponse) { type = .withoutResponse }
            else { trace("Strategy \(strategy.rawValue): no write-without-response; using acknowledged writes"); type = .withResponse }
        }
        let size = min(BLESendTuning.maximumPacket, peripheral.maximumWriteValueLength(for: type))
        trace("Send \(data.count) bytes; packet limit=\(size); mode=\(type == .withoutResponse ? "without response" : "with response"); strategy=\(strategy.rawValue)")
        guard size > 0 else { throw PrintFailure("Invalid BLE packet size") }
        let started = now
        let windowed = strategy == .windowed && type == .withoutResponse
        for offset in stride(from: 0, to: data.count, by: size) {
            try Task.checkCancellation()
            let packet = data.subdata(in: offset..<min(offset + size, data.count))
            if type == .withoutResponse {
                while true {
                    let decision = windowed
                        ? window.next(at: now, canSend: peripheral.canSendWriteWithoutResponse)
                        : (peripheral.canSendWriteWithoutResponse ? .go : .wait(timeout: nil))
                    guard case .wait(let timeout) = decision else { break }
                    try await waitForFlow(timeout: timeout)
                }
                guard peripheral.state == .connected, writeCharacteristic != nil else { throw PrintFailure("Printer disconnected") }
                if discardPending { received = Data(); discardPending = false }
                peripheral.writeValue(packet, for: characteristic, type: type)
                if windowed { window.noteSent(at: now) }
            } else {
                if discardPending { received = Data(); discardPending = false }
                try await withCheckedThrowingContinuation { continuation in
                    writeWaiter = continuation; arm(10, message: "Printer did not acknowledge a BLE write")
                    peripheral.writeValue(packet, for: characteristic, type: type)
                }
            }
            if strategy == .ackedPaced { try await Task.sleep(for: .seconds(BLESendTuning.ackedPause)) }
        }
        let elapsed = now - started
        jobBytes += data.count
        trace(String(format: "Chunk sent: %d bytes in %.0f ms (%.1f kB/s)", data.count, elapsed * 1000, elapsed > 0 ? Double(data.count) / 1000 / elapsed : 0))
    }
    /// Suspends until readiness, a notification, or `timeout`; a stall past 10 s fails the job.
    private func waitForFlow(timeout: TimeInterval?) async throws {
        try await withCheckedThrowingContinuation { continuation in
            flowWaiter = continuation; arm(10, message: "Printer stopped accepting data")
            flowTimer?.cancel()
            flowTimer = timeout.map { seconds in
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(0, seconds)))
                    if !Task.isCancelled { self?.wakeFlow() }
                }
            }
        }
    }
    private func wakeFlow() {
        flowTimer?.cancel(); flowTimer = nil
        guard let waiter = flowWaiter else { return }
        deadline?.cancel(); flowWaiter = nil; waiter.resume()
    }
    func settleInFlight() async throws {
        while case .wait(let timeout) = window.drain(at: now) {
            try Task.checkCancellation()
            try await waitForFlow(timeout: timeout)
        }
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard self.peripheral === peripheral else { return }
        wakeFlow()
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral else { return }
        if let error { fail(error); return }
        guard self.peripheral === peripheral, let waiter = writeWaiter else { return }
        deadline?.cancel(); writeWaiter = nil; waiter.resume()
    }
    func response(seconds: Double, predicate: @escaping (Data) -> Bool) async throws -> Data {
        if predicate(received) { return received }
        return try await withCheckedThrowingContinuation { continuation in
            replyWaiter = continuation; replyPredicate = predicate
            arm(seconds, message: "Printer did not confirm completion. Check the paper before retrying.")
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral else { return }
        if let error { fail(error); return }
        guard characteristic === notifyCharacteristic || characteristic === auxNotifyCharacteristic,
              let data = characteristic.value else { return }
        trace(BLETrace.notification(from: characteristic.uuid.uuidString, data))
        window.noteNotification(at: now)
        wakeFlow()
        received.append(data)
        if received.count > 65536 { fail(PrintFailure("Unexpected printer response size")); return }
        if let predicate = replyPredicate, predicate(received) {
            deadline?.cancel(); let waiter = replyWaiter; replyWaiter = nil; replyPredicate = nil; waiter?.resume(returning: received)
        }
    }
    func discardReplies() { received = Data(); discardPending = true }
    func printJob(_ job: PrintJob, to device: CBPeripheral) async throws {
        trace("Print requested: \(job.chunks.count) chunks; Bluetooth state=\(central.state.rawValue)")
        guard !busy, job.chunks.count >= 2 else { throw PrintFailure("Printer is busy or job is empty") }
        busy = true
        strategy = settings.sendStrategy
        window = SendWindow(); jobBytes = 0; discardPending = false
        jobStart = now
        trace("Print job started: strategy=\(strategy.rawValue); window=\(BLESendTuning.window)")
        defer { busy = false; deadline?.cancel() }
        do {
            message = "Connecting to \(device.name ?? "S1")…"
            try await connect(device)
            try await PrintExchange.run(job, channel: self) { message = $0 }
            trace(String(format: "Print job finished: %d bytes in %.1f s; strategy=%@", jobBytes, now - jobStart, strategy.rawValue))
            try await Task.sleep(for: .milliseconds(1500))
            message = "Printing completed"
        } catch {
            trace(String(format: "Print job failed after %d bytes, %.1f s; strategy=%@", jobBytes, now - jobStart, strategy.rawValue))
            fail(error); message = error.localizedDescription; throw error }
    }
}
