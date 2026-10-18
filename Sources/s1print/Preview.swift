import CoreGraphics
import Foundation
import ImageIO
import S1Kit
import UniformTypeIdentifiers

/// Renders what the printhead would receive as a PNG, for checking jobs without paper.
enum Preview {
    static func write(pages: [GrayPage], options: PrintOptions, to url: URL) throws {
        var bitmaps: [BitImage] = []
        let crop = GrayPage.sharedInkColumns(of: pages.filter { !$0.isBlank() })
        for page in pages where !page.isBlank() {
            let source = (options.fitContentWidth ? crop.map { page.cropped(toColumns: $0) } : nil) ?? page
            var fitted = source.fitted(toWidth: options.headWidthDots)
            if options.trimBottom { fitted = fitted.trimmingVertical() }
            if options.maxBlankRows > 0 { fitted = fitted.collapsingBlankRuns(maxRows: options.maxBlankRows) }
            bitmaps.append(Dither.pack(fitted, mode: options.dither))
        }
        let width = options.headWidthDots
        let gap = 12
        let height = bitmaps.reduce(0) { $0 + $1.height + gap }
        var pixels = [UInt8](repeating: 200, count: width * max(1, height))
        var top = 0
        for bm in bitmaps {
            for y in 0..<bm.height {
                for x in 0..<width {
                    let on = bm.rows[y * bm.widthBytes + (x >> 3)] & (0x80 >> (x & 7)) != 0
                    pixels[(top + y) * width + x] = on ? 0 : 255
                }
            }
            top += bm.height + gap
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: max(1, height), bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.unreadable(url.path)
        }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
