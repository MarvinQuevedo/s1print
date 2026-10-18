import CoreGraphics
import CoreText
import Foundation
import ImageIO
import S1Kit

enum RenderError: Error, CustomStringConvertible {
    case unreadable(String)
    var description: String {
        switch self { case .unreadable(let path): return "cannot read \(path) as a PDF, image or raster file" }
    }
}

/// Turns files into grayscale pages at the printhead width.
enum Renderer {
    static func pages(from url: URL, width: Int) throws -> [GrayPage] {
        let data = try Data(contentsOf: url)
        if RasterDecoder.isRaster(data) { return try RasterDecoder.decode(data) }
        if data.starts(with: Array("%PDF".utf8)) { return try pdfPages(data, width: width) }
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return [gray(of: image, width: width)]
        }
        throw RenderError.unreadable(url.path)
    }

    /// Renders every PDF page scaled so its width fills the printhead.
    static func pdfPages(_ data: Data, width: Int) throws -> [GrayPage] {
        guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider) else {
            throw RenderError.unreadable("PDF")
        }
        var pages: [GrayPage] = []
        for i in 1...max(1, doc.numberOfPages) {
            guard let page = doc.page(at: i) else { continue }
            let box = page.getBoxRect(.cropBox)
            let scale = CGFloat(width) / box.width
            let height = max(1, Int((box.height * scale).rounded()))
            pages.append(draw(width: width, height: height) { ctx in
                ctx.scaleBy(x: scale, y: scale)
                ctx.translateBy(x: -box.minX, y: -box.minY)
                ctx.drawPDFPage(page)
            })
        }
        return pages
    }

    static func gray(of image: CGImage, width: Int) -> GrayPage {
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        return draw(width: width, height: height) { ctx in
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// Draws into a white 8-bit gray bitmap; the closure gets PDF-style coordinates (origin bottom-left).
    static func draw(width: Int, height: Int, _ body: (CGContext) -> Void) -> GrayPage {
        var pixels = [UInt8](repeating: 255, count: width * height)
        pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            body(ctx)
        }
        return GrayPage(width: width, height: height, dpi: 203, pixels: pixels)
    }

    /// A self-test page: name, battery, a gray ramp and a ruler.
    static func testPage(width: Int, lines: [String]) -> GrayPage {
        let lineHeight = 30
        let height = 60 + lines.count * lineHeight + 120
        return draw(width: width, height: height) { ctx in
            func text(_ s: String, y: Int, size: CGFloat, bold: Bool = false) {
                let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
                let attr = NSAttributedString(string: s, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
                ])
                let line = CTLineCreateWithAttributedString(attr)
                ctx.textPosition = CGPoint(x: 8, y: CGFloat(height - y))
                CTLineDraw(line, ctx)
            }
            ctx.setStrokeColor(gray: 0, alpha: 1)
            ctx.setLineWidth(3)
            ctx.stroke(CGRect(x: 2, y: 2, width: width - 4, height: height - 4))
            text("s1print", y: 44, size: 30, bold: true)
            for (i, l) in lines.enumerated() { text(l, y: 60 + (i + 1) * lineHeight - 6, size: 20) }
            // Gray ramp: shows how dithering renders tones.
            let rampTop = height - 110
            for x in 0..<(width - 16) {
                ctx.setFillColor(gray: CGFloat(x) / CGFloat(width - 16), alpha: 1)
                ctx.fill(CGRect(x: 8 + x, y: 40, width: 1, height: rampTop - 40 - 10 > 0 ? 40 : 30))
            }
            // Ruler: a tick every 8 dots (1 mm).
            ctx.setLineWidth(1)
            for x in stride(from: 8, to: width - 8, by: 8) {
                let long = (x - 8) % 80 == 0
                ctx.move(to: CGPoint(x: x, y: 8)); ctx.addLine(to: CGPoint(x: x, y: long ? 30 : 18))
            }
            ctx.strokePath()
        }
    }
}
