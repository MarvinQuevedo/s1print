import Foundation

/// Transport diagnostics shared by the app and the Share Extension. Both processes write the same
/// file in the App Group container so it can be pulled from a Mac with `devicectl`.
/// Only transport metadata and printer status bytes are logged, never document or raster bytes.
enum BLETrace {
    static let fileName = "ble-diagnostics.log"
    static let capBytes = 64 * 1024
    static let keepBytes = 32 * 1024
    static let maximumHexBytes = 32

    /// `Library/Caches/ble-diagnostics.log` in the App Group container (own caches folder as a fallback).
    static func logURL() -> URL? {
        let manager = FileManager.default
        let base = manager.containerURL(forSecurityApplicationGroupIdentifier: Inbox.group)?
            .appendingPathComponent("Library/Caches", isDirectory: true)
            ?? manager.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let base else { return nil }
        try? manager.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(fileName)
    }

    static func log(_ event: String) {
        NSLog("S1Print BLE: %@", event)
        guard let url = logURL() else { return }
        append(event, to: url)
    }

    /// Appends one timestamped line; past the cap the file is trimmed to its newest `keepBytes`.
    static func append(_ event: String, to url: URL, now: Date = Date()) {
        let line = Data("\(now.ISO8601Format()) \(event)\n".utf8)
        let manager = FileManager.default
        let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        do {
            if let size, size > capBytes {
                var data = (try Data(contentsOf: url)).suffix(keepBytes)
                // Start on a whole line.
                if let newline = data.firstIndex(of: 0x0A) { data = data[data.index(after: newline)...] }
                var trimmed = Data(data); trimmed.append(line)
                try trimmed.write(to: url, options: .atomic)
            } else if size != nil {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
            }
        } catch { NSLog("S1Print BLE log write failed: %@", error.localizedDescription) }
    }

    /// Upper-case hex pairs, at most `maximumHexBytes` bytes; longer input ends with the number omitted.
    static func hex(_ data: Data) -> String {
        let shown = data.prefix(maximumHexBytes).map { String(format: "%02X", $0) }.joined(separator: " ")
        return data.count > maximumHexBytes ? "\(shown) …(+\(data.count - maximumHexBytes) more)" : shown
    }

    static func notification(from characteristic: String, _ data: Data) -> String {
        "Notification \(characteristic) \(data.count) bytes: \(hex(data))"
    }
}
