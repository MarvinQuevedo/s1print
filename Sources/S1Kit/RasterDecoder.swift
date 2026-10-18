import Foundation

public enum RasterError: Error, CustomStringConvertible {
    case unknownFormat
    case truncated(String)
    case unsupported(String)

    public var description: String {
        switch self {
        case .unknownFormat: return "not a PWG (RaS2) or Apple (UNIRAST) raster stream"
        case .truncated(let what): return "raster stream ends early: \(what)"
        case .unsupported(let what): return "unsupported raster: \(what)"
        }
    }
}

/// Decodes the two raster formats an IPP Everywhere / AirPrint client sends:
/// PWG Raster ("RaS2", PWG 5102.4) and Apple Raster ("UNIRAST", URF).
/// Both use the same PackBits-style line compression.
public enum RasterDecoder {
    public static func isRaster(_ data: Data) -> Bool {
        data.starts(with: Array("RaS2".utf8)) || data.starts(with: Array("UNIRAST".utf8))
    }

    public static func decode(_ data: Data) throws -> [GrayPage] {
        let bytes = [UInt8](data)
        if bytes.starts(with: Array("RaS2".utf8)) { return try decodePWG(bytes) }
        if bytes.starts(with: Array("UNIRAST".utf8)) { return try decodeURF(bytes) }
        throw RasterError.unknownFormat
    }

    // MARK: PWG Raster

    private static func decodePWG(_ b: [UInt8]) throws -> [GrayPage] {
        var pos = 4
        var pages: [GrayPage] = []
        while pos + 1796 <= b.count {
            let h = pos
            let dpi = Int(be32(b, h + 276))
            let width = Int(be32(b, h + 372))
            let height = Int(be32(b, h + 376))
            let bpp = Int(be32(b, h + 388))
            let colorSpace = Int(be32(b, h + 400))
            pos += 1796
            let kind = try PixelKind(bitsPerPixel: bpp, pwgColorSpace: colorSpace)
            let (page, next) = try decodeBitmap(b, at: pos, width: width, height: height, dpi: dpi, kind: kind)
            pages.append(page)
            pos = next
        }
        if pages.isEmpty { throw RasterError.truncated("no PWG page header") }
        return pages
    }

    // MARK: Apple Raster (URF)

    private static func decodeURF(_ b: [UInt8]) throws -> [GrayPage] {
        guard b.count >= 12 else { throw RasterError.truncated("URF file header") }
        let pageCount = Int(be32(b, 8))
        var pos = 12
        var pages: [GrayPage] = []
        while pos + 32 <= b.count && (pageCount == 0 || pages.count < pageCount) {
            let bpp = Int(b[pos])
            let colorSpace = Int(b[pos + 1])
            let width = Int(be32(b, pos + 12))
            let height = Int(be32(b, pos + 16))
            let dpi = Int(be32(b, pos + 20))
            pos += 32
            let kind = try PixelKind(bitsPerPixel: bpp, urfColorSpace: colorSpace)
            let (page, next) = try decodeBitmap(b, at: pos, width: width, height: height, dpi: dpi, kind: kind)
            pages.append(page)
            pos = next
        }
        if pages.isEmpty { throw RasterError.truncated("no URF page header") }
        return pages
    }

    // MARK: Shared bitmap decompression

    enum PixelKind {
        case black1      // 1 bit per pixel, 1 = black
        case gray8       // 0 = black
        case black8      // 0 = white (K / device gray inverted)
        case rgb24
        case rgba32

        init(bitsPerPixel bpp: Int, pwgColorSpace cs: Int) throws {
            switch (bpp, cs) {
            case (1, _): self = .black1
            case (8, 3): self = .black8      // CUPS_CSPACE_K
            case (8, _): self = .gray8       // sgray (18) or W
            case (24, _): self = .rgb24
            case (32, _): self = .rgba32
            default: throw RasterError.unsupported("PWG \(bpp) bpp, colour space \(cs)")
            }
        }

        init(bitsPerPixel bpp: Int, urfColorSpace cs: Int) throws {
            switch bpp {
            case 8: self = .gray8
            case 24: self = .rgb24
            case 32: self = .rgba32
            default: throw RasterError.unsupported("URF \(bpp) bpp, colour space \(cs)")
            }
        }

        /// Size of one compression unit in bytes.
        var unitBytes: Int {
            switch self {
            case .black1, .gray8, .black8: return 1
            case .rgb24: return 3
            case .rgba32: return 4
            }
        }

        func bytesPerLine(width: Int) -> Int {
            self == .black1 ? (width + 7) / 8 : width * unitBytes
        }

        /// Byte value of a white unit, used by the "fill rest of line" code.
        var whiteByte: UInt8 { (self == .black1 || self == .black8) ? 0x00 : 0xFF }
    }

    static func decodeBitmap(_ b: [UInt8], at start: Int, width: Int, height: Int, dpi: Int, kind: PixelKind) throws -> (GrayPage, Int) {
        guard width > 0, height > 0, width < 20000, height < 200000 else {
            throw RasterError.unsupported("page size \(width)x\(height)")
        }
        let unit = kind.unitBytes
        let lineBytes = kind.bytesPerLine(width: width)
        var pos = start
        var out = [UInt8](repeating: 255, count: width * height)
        var line = [UInt8](repeating: 0, count: lineBytes)
        var y = 0
        while y < height {
            guard pos < b.count else { throw RasterError.truncated("line \(y) of \(height)") }
            let repeats = Int(b[pos]) + 1
            pos += 1
            var filled = 0
            while filled < lineBytes {
                guard pos < b.count else { throw RasterError.truncated("line \(y) data") }
                let code = Int(b[pos]); pos += 1
                if code == 128 {
                    for i in filled..<lineBytes { line[i] = kind.whiteByte }
                    filled = lineBytes
                } else if code < 128 {
                    let count = code + 1
                    guard pos + unit <= b.count else { throw RasterError.truncated("repeat run") }
                    for _ in 0..<count where filled + unit <= lineBytes {
                        for k in 0..<unit { line[filled + k] = b[pos + k] }
                        filled += unit
                    }
                    pos += unit
                } else {
                    let count = 257 - code
                    let n = count * unit
                    guard pos + n <= b.count else { throw RasterError.truncated("literal run") }
                    let take = min(n, lineBytes - filled)
                    for k in 0..<take { line[filled + k] = b[pos + k] }
                    filled += take
                    pos += n
                }
            }
            let gray = toGray(line, width: width, kind: kind)
            for _ in 0..<repeats where y < height {
                out.replaceSubrange(y * width..<(y + 1) * width, with: gray)
                y += 1
            }
        }
        return (GrayPage(width: width, height: height, dpi: dpi > 0 ? dpi : 203, pixels: out), pos)
    }

    private static func toGray(_ line: [UInt8], width: Int, kind: PixelKind) -> [UInt8] {
        var g = [UInt8](repeating: 255, count: width)
        switch kind {
        case .black1:
            for x in 0..<width where line[x >> 3] & (0x80 >> (x & 7)) != 0 { g[x] = 0 }
        case .gray8:
            for x in 0..<width { g[x] = line[x] }
        case .black8:
            for x in 0..<width { g[x] = 255 &- line[x] }
        case .rgb24, .rgba32:
            let u = kind.unitBytes
            for x in 0..<width {
                let r = Int(line[x * u]), gr = Int(line[x * u + 1]), bl = Int(line[x * u + 2])
                g[x] = UInt8((r * 299 + gr * 587 + bl * 114) / 1000)
            }
        }
        return g
    }

    @inline(__always) static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
}
