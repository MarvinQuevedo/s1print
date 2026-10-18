import Foundation

/// Command set of the Luck Jingle S1 (Xiamen Lujiang "LuckPrinter" family).
///
/// Verified on an S1 (model string `S1_LYiN48D_GY`, firmware V3.0.3) over
/// classic Bluetooth SPP. See docs/PROTOCOL.md for the evidence of each command.
public enum S1Command {
    public static let getModel = Data([0x10, 0xFF, 0x20, 0xF0])
    public static let getFirmware = Data([0x10, 0xFF, 0x20, 0xF1])
    public static let getSerial = Data([0x10, 0xFF, 0x20, 0xF2])
    public static let getBattery = Data([0x10, 0xFF, 0x50, 0xF1])
    public static let getStatus = Data([0x10, 0xFF, 0x40])
    public static let getShutdownMinutes = Data([0x10, 0xFF, 0x13])
    public static let getAllInfo = Data([0x10, 0xFF, 0x70])

    public static let wake = Data(count: 12)
    /// Lujiang devices: start a print. (AiYin devices use 10 FF FE 01 instead.)
    public static let enable = Data([0x10, 0xFF, 0xF1, 0x03])
    /// Lujiang devices: end a print; the printer answers "OK" when it is done.
    public static let stop = Data([0x10, 0xFF, 0xF1, 0x45])
    public static let formFeed = Data([0x1D, 0x0C])

    /// 0 = light, 1 = medium, 2 = dark.
    public static func density(_ level: Int) -> Data {
        Data([0x10, 0xFF, 0x10, 0x00, UInt8(max(0, min(2, level)))])
    }

    /// Feed paper forward by `dots` (1/203 in).
    public static func feed(dots: Int) -> Data {
        var d = Data()
        var left = max(0, dots)
        while left > 0 {
            let n = min(255, left)
            d.append(contentsOf: [0x1B, 0x4A, UInt8(n)])
            left -= n
        }
        return d
    }

    /// ESC/POS "GS v 0" raster block.
    public static func raster(widthBytes: Int, rows: ArraySlice<UInt8>) -> Data {
        let height = rows.count / widthBytes
        var d = Data([0x1D, 0x76, 0x30, 0x00,
                      UInt8(widthBytes & 0xFF), UInt8(widthBytes >> 8),
                      UInt8(height & 0xFF), UInt8(height >> 8)])
        d.append(contentsOf: rows)
        return d
    }
}

public struct S1Status: CustomStringConvertible {
    public let raw: UInt8
    public var printing: Bool { raw & 0x01 != 0 }
    public var coverOpen: Bool { raw & 0x02 != 0 }
    public var outOfPaper: Bool { raw & 0x04 != 0 }
    public var lowBattery: Bool { raw & 0x08 != 0 }
    public var overheated: Bool { raw & 0x50 != 0 }
    public var charging: Bool { raw & 0x20 != 0 }
    public var ready: Bool { raw & 0x5E == 0 }

    public init(raw: UInt8) { self.raw = raw }

    /// IPP printer-state-reasons keywords for ippeveprinter.
    public var ippReasons: [String] {
        var r: [String] = []
        if coverOpen { r.append("cover-open") }
        if outOfPaper { r.append("media-empty") }
        if lowBattery { r.append("marker-supply-low") }
        if overheated { r.append("other") }
        return r.isEmpty ? ["none"] : r
    }

    public var description: String {
        var parts: [String] = []
        if printing { parts.append("printing") }
        if coverOpen { parts.append("cover open") }
        if outOfPaper { parts.append("out of paper") }
        if lowBattery { parts.append("low battery") }
        if overheated { parts.append("overheated") }
        if charging { parts.append("charging") }
        return parts.isEmpty ? "ready" : parts.joined(separator: ", ")
    }
}

public struct PrintOptions {
    /// Printhead width in bytes: 48 bytes = 384 dots = 48 mm at 203 dpi.
    public var headWidthBytes = 48
    public var density = 1
    public var dither: DitherMode = .auto
    /// Paper fed after each page, in dots (203 per inch).
    public var feedAfterPage = 64
    /// Use the label-gap form feed (1D 0C) instead of a fixed feed.
    public var labelPaper = false
    /// Remove blank rows above and below the content (receipts on a roll).
    public var trimBottom = false
    /// Longest run of blank rows ever sent; 160 dots = 20 mm. 0 disables the cap.
    public var maxBlankRows = 160
    /// Crop empty side margins and scale the content to the full head width.
    public var fitContentWidth = false
    /// Rows per GS v 0 block; small blocks keep the printer's buffer from overflowing.
    public var rowsPerBlock = 255

    public init() {}

    public var headWidthDots: Int { headWidthBytes * 8 }
}

public enum S1JobBuilder {
    /// Builds the full byte stream for a job. Each element is one write unit;
    /// the transport paces them so the printer can keep up.
    public static func build(pages: [GrayPage], options: PrintOptions) -> [Data] {
        var out: [Data] = [S1Command.density(options.density), S1Command.wake, S1Command.enable]
        let printable = pages.filter { !$0.isBlank() }
        let crop = GrayPage.sharedInkColumns(of: printable)
        for (index, page) in printable.enumerated() {
            let source = (options.fitContentWidth ? crop.map { page.cropped(toColumns: $0) } : nil) ?? page
            var fitted = source.fitted(toWidth: options.headWidthDots)
            if options.trimBottom { fitted = fitted.trimmingVertical() }
            if options.maxBlankRows > 0 { fitted = fitted.collapsingBlankRuns(maxRows: options.maxBlankRows) }
            let bitmap = Dither.pack(fitted, mode: options.dither)
            var row = 0
            while row < bitmap.height {
                let n = min(options.rowsPerBlock, bitmap.height - row)
                let slice = bitmap.rows[row * bitmap.widthBytes..<(row + n) * bitmap.widthBytes]
                out.append(S1Command.raster(widthBytes: bitmap.widthBytes, rows: slice))
                row += n
            }
            if options.labelPaper {
                out.append(S1Command.formFeed)
            } else if options.feedAfterPage > 0 && (index == printable.count - 1 || !options.trimBottom) {
                out.append(S1Command.feed(dots: options.feedAfterPage))
            }
        }
        out.append(S1Command.stop)
        return out
    }
}
