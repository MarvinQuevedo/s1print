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

    /// Box-filter resample to a new width, preserving the aspect ratio.
    public func scaled(toWidth newWidth: Int) -> GrayPage {
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
}
