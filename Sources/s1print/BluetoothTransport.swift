import Foundation
import IOBluetooth

enum TransportError: Error, CustomStringConvertible {
    case noPrinter(String)
    case noSerialService
    case openFailed(IOReturn)
    case writeFailed(IOReturn)
    case timeout(String)

    var description: String {
        switch self {
        case .noPrinter(let hint): return "no paired S1 printer found (\(hint)); pair it in System Settings → Bluetooth"
        case .noSerialService: return "the printer did not publish a serial port (SPP) service"
        case .openFailed(let r): return String(format: "could not open the Bluetooth channel (0x%08x); is the printer on?", r)
        case .writeFailed(let r): return String(format: "Bluetooth write failed (0x%08x)", r)
        case .timeout(let what): return "timed out waiting for \(what)"
        }
    }
}

/// Classic Bluetooth RFCOMM link to the printer.
///
/// We open the SPP channel ourselves through IOBluetooth instead of using
/// /dev/cu.*: the S1 drops the baseband link a few seconds after connecting
/// unless an RFCOMM channel is opened, and the tty device does not reliably
/// open one. Requires the Bluetooth privacy permission (the app bundle's
/// Info.plist carries NSBluetoothAlwaysUsageDescription).
final class BluetoothTransport: NSObject, IOBluetoothRFCOMMChannelDelegate {
    private let device: IOBluetoothDevice
    private var channel: IOBluetoothRFCOMMChannel?
    private var inbox = Data()
    private(set) var closedByPeer = false

    static let defaultNamePrefixes = ["PPS1", "S1_", "LuckP"]

    init(address: String?) throws {
        if let address, let d = IOBluetoothDevice(addressString: address) {
            device = d
        } else {
            let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
            guard let d = paired.first(where: { dev in
                let name = dev.name ?? ""
                return BluetoothTransport.defaultNamePrefixes.contains { name.hasPrefix($0) }
            }) else {
                throw TransportError.noPrinter(address ?? "looked for names starting with \(BluetoothTransport.defaultNamePrefixes.joined(separator: ", "))")
            }
            device = d
        }
        super.init()
    }

    var name: String { device.name ?? device.addressString ?? "S1" }
    var address: String { device.addressString ?? "" }

    func open() throws {
        if !device.isConnected() { _ = device.openConnection() }
        var channelID: BluetoothRFCOMMChannelID = 1
        let spp = IOBluetoothSDPUUID(uuid16: 0x1101)
        var record = device.getServiceRecord(for: spp)
        if record == nil {
            _ = device.performSDPQuery(nil)
            Self.pump(2.5)
            record = device.getServiceRecord(for: spp)
        }
        if let record {
            var id: BluetoothRFCOMMChannelID = 0
            if record.getRFCOMMChannelID(&id) == kIOReturnSuccess { channelID = id }
        }
        var ch: IOBluetoothRFCOMMChannel?
        var result = kIOReturnError
        for attempt in 0..<3 {
            result = device.openRFCOMMChannelSync(&ch, withChannelID: channelID, delegate: self)
            if result == kIOReturnSuccess { break }
            Self.pump(1.0 + Double(attempt))
        }
        guard result == kIOReturnSuccess, let ch else { throw TransportError.openFailed(result) }
        channel = ch
        Self.pump(0.3)
    }

    func close() {
        channel?.close()
        channel = nil
        Self.pump(0.2)
    }

    /// Writes all bytes in MTU-sized pieces, optionally throttled to `bytesPerSecond`.
    func write(_ data: Data, bytesPerSecond: Int? = nil) throws {
        guard let channel else { throw TransportError.openFailed(kIOReturnNotOpen) }
        let mtu = max(20, Int(channel.getMTU()))
        var offset = 0
        let start = Date()
        while offset < data.count {
            var chunk = [UInt8](data[data.startIndex + offset..<data.startIndex + min(offset + mtu, data.count)])
            let r = channel.writeSync(&chunk, length: UInt16(chunk.count))
            guard r == kIOReturnSuccess else { throw TransportError.writeFailed(r) }
            offset += chunk.count
            if let rate = bytesPerSecond, rate > 0 {
                let due = Double(offset) / Double(rate)
                let ahead = due - Date().timeIntervalSince(start)
                Self.pump(max(0.001, ahead))
            } else {
                Self.pump(0.001)
            }
        }
    }

    /// Sends a command and returns whatever the printer answers within `wait` seconds.
    func query(_ command: Data, wait: TimeInterval = 1.0) throws -> Data {
        inbox.removeAll()
        try write(command)
        let deadline = Date().addingTimeInterval(wait)
        var lastCount = 0, quietSince = Date()
        while Date() < deadline {
            Self.pump(0.05)
            if inbox.count != lastCount { lastCount = inbox.count; quietSince = Date() }
            if !inbox.isEmpty && Date().timeIntervalSince(quietSince) > 0.25 { break }
        }
        return inbox
    }

    /// Waits until the received bytes contain `token` (for example "OK").
    func waitFor(_ token: Data, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if inbox.range(of: token) != nil { return true }
            if closedByPeer { return false }
            Self.pump(0.05)
        }
        return false
    }

    func clearInbox() { inbox.removeAll() }
    var received: Data { inbox }

    // MARK: IOBluetoothRFCOMMChannelDelegate

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        inbox.append(Data(bytes: dataPointer, count: dataLength))
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        closedByPeer = true
    }

    static func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
