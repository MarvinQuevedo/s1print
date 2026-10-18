import Foundation

/// User settings, stored as JSON in ~/Library/Application Support/s1print/settings.json.
struct Settings: Codable {
    /// Bluetooth address of the printer; nil picks the first paired S1.
    var address: String?
    var density = 1
    /// Optional cap on the Bluetooth send rate; 0 lets RFCOMM flow control set the pace.
    /// Pacing below the print speed starves the head and leaves white bands.
    var bytesPerSecond = 0
    var ippPort = 8631
    var serviceName = "S1 Bluetooth"

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("s1print", isDirectory: true)
    }

    static var file: URL { directory.appendingPathComponent("settings.json") }

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: file),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return s
    }

    func save() {
        try? FileManager.default.createDirectory(at: Settings.directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Settings.file)
    }
}

/// Paper sizes the virtual printer offers. Width in 1/100 mm.
struct MediaSize {
    let name: String
    let width: Int
    let height: Int
    let sideMargin: Int

    // No side margins: the whole page width is scaled onto the 48 mm head, so
    // nothing an app draws near the edge is lost.
    static let all: [MediaSize] = [
        // Continuous roll: long page, the blank tail is cut off before printing.
        MediaSize(name: "oe_s1-roll-58mm_58x600mm", width: 5800, height: 60000, sideMargin: 0),
        // 80 mm receipts are scaled down to the 48 mm head.
        MediaSize(name: "oe_s1-roll-80mm_80x600mm", width: 8000, height: 60000, sideMargin: 0),
        MediaSize(name: "oe_s1-58x30mm_58x30mm", width: 5800, height: 3000, sideMargin: 0),
        MediaSize(name: "oe_s1-58x40mm_58x40mm", width: 5800, height: 4000, sideMargin: 0),
        MediaSize(name: "oe_s1-58x50mm_58x50mm", width: 5800, height: 5000, sideMargin: 0),
        MediaSize(name: "oe_s1-58x80mm_58x80mm", width: 5800, height: 8000, sideMargin: 0),
    ]

    var collection: String {
        "{MEMBER collection media-size {MEMBER integer x-dimension \(width) MEMBER integer y-dimension \(height)} " +
        "MEMBER integer media-left-margin \(sideMargin) MEMBER integer media-right-margin \(sideMargin) " +
        "MEMBER integer media-top-margin 0 MEMBER integer media-bottom-margin 0 " +
        "MEMBER keyword media-size-name \"\(name)\"}"
    }
}

/// Attributes file for ippeveprinter describing the S1 as an IPP Everywhere printer.
func ippeveConfig() -> String {
    let sizes = MediaSize.all
    let def = sizes[0]
    var lines: [String] = []
    lines.append("ATTR keyword media-supported " + sizes.map { "\"\($0.name)\"" }.joined(separator: ","))
    lines.append("ATTR keyword media-default \"\(def.name)\"")
    lines.append("ATTR keyword media-ready \"\(def.name)\"")
    lines.append("ATTR collection media-size-supported " + sizes.map {
        "{MEMBER integer x-dimension \($0.width) MEMBER integer y-dimension \($0.height)}"
    }.joined(separator: ","))
    lines.append("ATTR collection media-col-database " + sizes.map(\.collection).joined(separator: ","))
    lines.append("ATTR collection media-col-default " + def.collection)
    lines.append("ATTR collection media-col-ready " + def.collection)
    lines.append("ATTR keyword media-col-supported \"media-size\",\"media-left-margin\",\"media-right-margin\",\"media-top-margin\",\"media-bottom-margin\",\"media-size-name\"")
    lines.append("ATTR integer media-left-margin-supported 0")
    lines.append("ATTR integer media-right-margin-supported 0")
    lines.append("ATTR integer media-top-margin-supported 0")
    lines.append("ATTR integer media-bottom-margin-supported 0")
    lines.append("ATTR resolution pwg-raster-document-resolution-supported 203dpi")
    lines.append("ATTR resolution printer-resolution-supported 203dpi")
    lines.append("ATTR resolution printer-resolution-default 203dpi")
    lines.append("ATTR keyword pwg-raster-document-type-supported \"black_1\",\"sgray_8\"")
    lines.append("ATTR keyword urf-supported \"V1.4\",\"W8\",\"DM1\",\"RS203\",\"CP1\",\"IS1\",\"MT1-3-10-12\"")
    lines.append("ATTR keyword print-color-mode-supported \"monochrome\"")
    lines.append("ATTR keyword print-color-mode-default \"monochrome\"")
    lines.append("ATTR boolean color-supported false")
    lines.append("ATTR keyword print-content-optimize-supported \"auto\",\"text\",\"photo\",\"graphic\"")
    lines.append("ATTR keyword print-content-optimize-default \"auto\"")
    lines.append("ATTR text printer-make-and-model \"s1print Luck Jingle S1\"")
    lines.append("ATTR text printer-location \"Bluetooth\"")
    lines.append("ATTR text printer-info \"S1 thermal printer over Bluetooth (s1print)\"")
    return lines.joined(separator: "\n") + "\n"
}
