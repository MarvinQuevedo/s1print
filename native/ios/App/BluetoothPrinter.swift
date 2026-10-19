import Foundation
import CoreBluetooth
import Combine

enum BLEUARTProfile: CaseIterable {
    case ff00, uart18f0

    var serviceUUID: CBUUID { CBUUID(string: self == .ff00 ? "FF00" : "18F0") }
    var writeUUID: CBUUID { CBUUID(string: self == .ff00 ? "FF02" : "2AF1") }
    var notifyUUID: CBUUID { CBUUID(string: self == .ff00 ? "FF01" : "2AF0") }

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
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var writeWaiter: CheckedContinuation<Void, Error>?
    private var flowWaiter: CheckedContinuation<Void, Error>?
    private var replyWaiter: CheckedContinuation<Data, Error>?
    private var replyPredicate: ((Data) -> Bool)?
    private var received = Data()
    private var deadline: Task<Void, Never>?
    private var scanDeadline: Task<Void, Never>?
    private var disconnecting = false

    private func trace(_ event: String) {
        NSLog("S1Print BLE: %@", event)
        // Keep transport metadata only; never persist document or raster bytes.
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let url = directory.appendingPathComponent("ble-diagnostics.log")
        var data = (try? Data(contentsOf: url)) ?? Data()
        if data.count > 65536 { data = Data(data.suffix(32768)) }
        data.append(Data("\(Date().ISO8601Format()) \(event)\n".utf8))
        do { try data.write(to: url, options: .atomic) }
        catch { NSLog("S1Print BLE log write failed: %@", error.localizedDescription) }
    }

    private func connectionStage(_ stage: String) {
        message = stage
        trace(stage)
        arm(15, message: "\(stage) timed out. No print data was sent.")
    }

    override convenience init() { self.init(settings: PrintSettings()) }
    init(settings: PrintSettings) {
        self.settings = settings
        super.init()
        trace("Transport initialized; acknowledged writes preferred; packet pause=10 ms")
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
        let flow = flowWaiter; flowWaiter = nil
        let reply = replyWaiter; replyWaiter = nil; replyPredicate = nil
        connect?.resume(throwing: error); write?.resume(throwing: error)
        flow?.resume(throwing: error); reply?.resume(throwing: error)
        writeCharacteristic = nil; notifyCharacteristic = nil
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
        writeCharacteristic = nil; notifyCharacteristic = nil
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
        connectionStage("Enabling printer notifications")
        peripheral.setNotifyValue(true, for: notify)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, connectWaiter != nil else { return }
        if let error { fail(error); return }
        guard characteristic === notifyCharacteristic, characteristic.isNotifying else { return }
        trace("Notifications enabled; printer transport ready")
        deadline?.cancel(); let waiter = connectWaiter; connectWaiter = nil; waiter?.resume()
    }
    func send(_ data: Data) async throws {
        guard let peripheral, let characteristic = writeCharacteristic, peripheral.state == .connected else { throw PrintFailure("Printer is disconnected") }
        // Host-side queue capacity does not represent the printer's receive buffer.
        // Prefer acknowledged writes when supported, and pace both write modes.
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        let size = min(512, peripheral.maximumWriteValueLength(for: type))
        trace("Send \(data.count) bytes; packet limit=\(size); mode=\(type == .withoutResponse ? "without response" : "with response")")
        guard size > 0 else { throw PrintFailure("Invalid BLE packet size") }
        for offset in stride(from: 0, to: data.count, by: size) {
            try Task.checkCancellation()
            let packet = data.subdata(in: offset..<min(offset + size, data.count))
            if type == .withoutResponse {
                if !peripheral.canSendWriteWithoutResponse {
                    try await withCheckedThrowingContinuation { continuation in
                        flowWaiter = continuation; arm(10, message: "Printer stopped accepting data")
                    }
                }
                guard peripheral.state == .connected, writeCharacteristic != nil else { throw PrintFailure("Printer disconnected") }
                peripheral.writeValue(packet, for: characteristic, type: type)
            } else {
                try await withCheckedThrowingContinuation { continuation in
                    writeWaiter = continuation; arm(10, message: "Printer did not acknowledge a BLE write")
                    peripheral.writeValue(packet, for: characteristic, type: type)
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard self.peripheral === peripheral, let waiter = flowWaiter else { return }
        deadline?.cancel(); flowWaiter = nil; waiter.resume()
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
        guard characteristic === notifyCharacteristic, let data = characteristic.value else { return }
        trace("Received \(data.count) reply bytes")
        received.append(data)
        if received.count > 65536 { fail(PrintFailure("Unexpected printer response size")); return }
        if let predicate = replyPredicate, predicate(received) {
            deadline?.cancel(); let waiter = replyWaiter; replyWaiter = nil; replyPredicate = nil; waiter?.resume(returning: received)
        }
    }
    func discardReplies() { received = Data() }
    func printJob(_ job: PrintJob, to device: CBPeripheral) async throws {
        trace("Print requested: \(job.chunks.count) chunks; Bluetooth state=\(central.state.rawValue)")
        guard !busy, job.chunks.count >= 2 else { throw PrintFailure("Printer is busy or job is empty") }
        busy = true
        defer { busy = false; deadline?.cancel() }
        do {
            message = "Connecting to \(device.name ?? "S1")…"
            try await connect(device)
            try await PrintExchange.run(job, channel: self) { message = $0 }
            try await Task.sleep(for: .milliseconds(1500))
            message = "Printing completed"
        } catch { fail(error); message = error.localizedDescription; throw error }
    }
}
