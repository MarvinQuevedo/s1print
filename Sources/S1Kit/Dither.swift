import Foundation

/// A 1-bit image packed MSB-first, 1 = black (heater on), as the printhead wants it.
public struct BitImage: Equatable {
    public let widthBytes: Int
    public let height: Int
    public var rows: [UInt8]

    public var width: Int { widthBytes * 8 }

    public init(widthBytes: Int, height: Int, rows: [UInt8]) {
        precondition(rows.count == widthBytes * height)
        self.widthBytes = widthBytes
        self.height = height
        self.rows = rows
    }
}

public enum DitherMode: String, CaseIterable {
    /// Threshold for line art and text, error diffusion when the page has photos.
    case auto
    /// Hard threshold at 50 %: sharpest text.
    case threshold
    /// Floyd–Steinberg error diffusion.
    case floyd
    /// Atkinson diffusion: lighter and crisper than Floyd–Steinberg on thermal paper.
    case atkinson
}

public enum Dither {
    /// Converts a grayscale page (already `width` pixels wide) to a packed bitmap.
    public static func pack(_ page: GrayPage, mode: DitherMode = .auto, threshold: Int = 128) -> BitImage {
        let resolved = mode == .auto ? (hasPhotographicContent(page) ? .atkinson : .threshold) : mode
        let w = page.width, h = page.height
        let widthBytes = (w + 7) / 8
        var bits = [UInt8](repeating: 0, count: widthBytes * h)

        switch resolved {
        case .threshold, .auto:
            for y in 0..<h {
                for x in 0..<w where Int(page.pixels[y * w + x]) < threshold {
                    bits[y * widthBytes + (x >> 3)] |= 0x80 >> (x & 7)
                }
            }
        case .floyd, .atkinson:
            var buf = page.pixels.map { Int16($0) }
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    let old = Int(buf[i])
                    let black = old < threshold
                    if black { bits[y * widthBytes + (x >> 3)] |= 0x80 >> (x & 7) }
                    let err = old - (black ? 0 : 255)
                    func spread(_ dx: Int, _ dy: Int, _ num: Int, _ den: Int) {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, nx < w, ny < h else { return }
                        let j = ny * w + nx
                        buf[j] = Int16(clamping: Int(buf[j]) + err * num / den)
                    }
                    if resolved == .floyd {
                        spread(1, 0, 7, 16); spread(-1, 1, 3, 16); spread(0, 1, 5, 16); spread(1, 1, 1, 16)
                    } else {
                        spread(1, 0, 1, 8); spread(2, 0, 1, 8); spread(-1, 1, 1, 8)
                        spread(0, 1, 1, 8); spread(1, 1, 1, 8); spread(0, 2, 1, 8)
                    }
                }
            }
        }
        return BitImage(widthBytes: widthBytes, height: h, rows: bits)
    }

    /// True when a noticeable share of the inked area is mid-tone gray,
    /// which is what photos look like; antialiased text has only thin edges.
    public static func hasPhotographicContent(_ page: GrayPage) -> Bool {
        var mid = 0, inked = 0
        for p in page.pixels where p < 245 {
            inked += 1
            if p > 40 && p < 215 { mid += 1 }
        }
        return inked > 0 && mid * 100 / inked > 35
    }
}
