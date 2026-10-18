import Foundation

/// An 8-bit grayscale page: 0 = black, 255 = white, row-major.
public struct GrayPage: Equatable {
    public var width: Int
    public var height: Int
    public var dpi: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, dpi: Int = 203, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "pixel buffer does not match size")
        self.width = width
        self.height = height
        self.dpi = dpi
        self.pixels = pixels
    }

    public init(width: Int, height: Int, dpi: Int = 203, fill: UInt8 = 255) {
        self.init(width: width, height: height, dpi: dpi, pixels: [UInt8](repeating: fill, count: width * height))
    }

    public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Fits the page to the printhead width by scaling the whole page width,
    /// keeping the aspect ratio. The virtual printer declares no side margins,
    /// so the page edge is the paper edge and nothing is cropped.
    public func fitted(toWidth headWidth: Int) -> GrayPage {
        width == headWidth ? self : scaled(toWidth: headWidth)
    }

    /// Resamples to a new width, preserving the aspect ratio: area averaging
    /// when shrinking, bilinear interpolation when enlarging (nearest-neighbour
    /// enlargement turns antialiased edges into broken, jagged strokes).
    public func scaled(toWidth newWidth: Int) -> GrayPage {
        if newWidth > width { return enlarged(toWidth: newWidth) }
        let newHeight = max(1, Int((Double(height) * Double(newWidth) / Double(width)).rounded()))
        var out = [UInt8](repeating: 255, count: newWidth * newHeight)
        let sx = Double(width) / Double(newWidth)
        let sy = Double(height) / Double(newHeight)
        for y in 0..<newHeight {
            let y0 = Int(Double(y) * sy), y1 = max(y0 + 1, min(height, Int(Double(y + 1) * sy)))
            for x in 0..<newWidth {
                let x0 = Int(Double(x) * sx), x1 = max(x0 + 1, min(width, Int(Double(x + 1) * sx)))
                var sum = 0
                for yy in y0..<y1 { for xx in x0..<x1 { sum += Int(pixels[yy * width + xx]) } }
                out[y * newWidth + x] = UInt8(sum / ((y1 - y0) * (x1 - x0)))
            }
        }
        return GrayPage(width: newWidth, height: newHeight, dpi: dpi * newWidth / max(1, width), pixels: out)
    }

    private func rowIsBlank(_ y: Int, threshold: UInt8) -> Bool {
        !pixels[y * width..<(y + 1) * width].contains(where: { $0 < threshold })
    }

    /// Drops fully white rows at the top and bottom (keeps at least one row).
    ///
    /// macOS places a page that is shorter than the roll "page" at the bottom
    /// of it, so a receipt on a 600 mm roll arrives with ~440 mm of white above.
    public func trimmingVertical(threshold: UInt8 = 250) -> GrayPage {
        var first = 0
        while first < height - 1 && rowIsBlank(first, threshold: threshold) { first += 1 }
        var last = height - 1
        while last > first && rowIsBlank(last, threshold: threshold) { last -= 1 }
        return GrayPage(width: width, height: last - first + 1, dpi: dpi,
                        pixels: Array(pixels[first * width..<(last + 1) * width]))
    }

    /// Shortens every run of blank rows longer than `maxRows` to `maxRows`,
    /// so a page that is mostly white cannot feed metres of empty paper.
    public func collapsingBlankRuns(maxRows: Int, threshold: UInt8 = 250) -> GrayPage {
        var out: [UInt8] = []
        out.reserveCapacity(pixels.count)
        var run = 0
        for y in 0..<height {
            if rowIsBlank(y, threshold: threshold) {
                run += 1
                if run > maxRows { continue }
            } else {
                run = 0
            }
            out.append(contentsOf: pixels[y * width..<(y + 1) * width])
        }
        return GrayPage(width: width, height: out.count / width, dpi: dpi, pixels: out)
    }

    /// True when no pixel is darker than `threshold`.
    public func isBlank(threshold: UInt8 = 250) -> Bool {
        !pixels.contains(where: { $0 < threshold })
    }

    private func enlarged(toWidth newWidth: Int) -> GrayPage {
        let newHeight = max(1, Int((Double(height) * Double(newWidth) / Double(width)).rounded()))
        var out = [UInt8](repeating: 255, count: newWidth * newHeight)
        let sx = Double(width) / Double(newWidth), sy = Double(height) / Double(newHeight)
        for y in 0..<newHeight {
            let fy = max(0, (Double(y) + 0.5) * sy - 0.5)
            let y0 = min(height - 1, Int(fy)), y1 = min(height - 1, y0 + 1), ty = fy - Double(y0)
            for x in 0..<newWidth {
                let fx = max(0, (Double(x) + 0.5) * sx - 0.5)
                let x0 = min(width - 1, Int(fx)), x1 = min(width - 1, x0 + 1), tx = fx - Double(x0)
                let a = Double(pixels[y0 * width + x0]), b = Double(pixels[y0 * width + x1])
                let c = Double(pixels[y1 * width + x0]), d = Double(pixels[y1 * width + x1])
                let v = (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
                out[y * newWidth + x] = UInt8(max(0, min(255, v.rounded())))
            }
        }
        return GrayPage(width: newWidth, height: newHeight, dpi: dpi * newWidth / max(1, width), pixels: out)
    }

    /// Columns that hold ink, or nil for a blank page.
    public func inkColumns(threshold: UInt8 = 250) -> ClosedRange<Int>? {
        var left = width, right = -1
        for y in 0..<height {
            let row = y * width
            var x = 0
            while x < min(left, width) { if pixels[row + x] < threshold { left = x; break }; x += 1 }
            x = width - 1
            while x > max(right, -1) { if pixels[row + x] < threshold { right = x; break }; x -= 1 }
        }
        return right >= left ? left...right : nil
    }

    /// Keeps only `columns` (clamped to the page).
    public func cropped(toColumns columns: ClosedRange<Int>) -> GrayPage {
        let x0 = max(0, columns.lowerBound), x1 = min(width - 1, columns.upperBound)
        let w = x1 - x0 + 1
        guard w > 0, w < width else { return self }
        var out = [UInt8](repeating: 255, count: w * height)
        for y in 0..<height {
            out.replaceSubrange(y * w..<(y + 1) * w, with: pixels[y * width + x0...y * width + x1])
        }
        return GrayPage(width: w, height: height, dpi: dpi, pixels: out)
    }

    /// The columns holding ink on any of `pages`, padded, for one shared crop.
    ///
    /// Browsers often lay a receipt out narrower than the paper (Safari drew a
    /// 58 mm ticket in 270 of 463 columns), so scaling the full page width made
    /// the print far too small. One range for the whole job keeps every page at
    /// the same scale.
    public static func sharedInkColumns(of pages: [GrayPage], padding: Int = 6) -> ClosedRange<Int>? {
        let ranges = pages.compactMap { $0.inkColumns() }
        guard let lo = ranges.map(\.lowerBound).min(), let hi = ranges.map(\.upperBound).max() else { return nil }
        return (lo - padding)...(hi + padding)
    }
}
