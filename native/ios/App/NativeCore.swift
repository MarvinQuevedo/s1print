import Foundation
import UIKit
import ImageIO
import PDFKit

struct NativePage: Encodable {
    let width: Int
    let height: Int
    let dpi = 406
    let pixels: Data
}
struct PrintOptions: Codable, Equatable {
    var density = 1
    var fitContentWidth = true
    var labelPaper = false
    var trimBottom: Bool { !labelPaper }
    /// BLE delivers far less than the print speed; blank runs of this many rows travel as a
    /// paper feed so the head is not starved mid-ticket (white bands, docs/PAPER.md).
    var blankRowsAsFeed: Int { 4 }
    enum CodingKeys: CodingKey { case density, fitContentWidth, labelPaper, trimBottom, blankRowsAsFeed }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        density = try values.decode(Int.self, forKey: .density)
        fitContentWidth = try values.decode(Bool.self, forKey: .fitContentWidth)
        labelPaper = try values.decode(Bool.self, forKey: .labelPaper)
    }
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(density, forKey: .density)
        try values.encode(fitContentWidth, forKey: .fitContentWidth)
        try values.encode(labelPaper, forKey: .labelPaper)
        try values.encode(trimBottom, forKey: .trimBottom)
        try values.encode(blankRowsAsFeed, forKey: .blankRowsAsFeed)
    }
}
struct PrintJob: Decodable {
    struct Preview: Decodable { let width: Int; let height: Int; let rows: Data }
    let chunks: [Data]
    let sourcePages: Int
    let preview: Preview
}
enum NativeCore {
    static let maximumPixels = 32 * 1024 * 1024
    static func call(_ data: Data) throws -> Data {
        let pointer = data.withUnsafeBytes { buffer in s1_process_json(buffer.bindMemory(to: UInt8.self).baseAddress, data.count) }
        guard let pointer else { throw PrintFailure("Rust processing returned no result") }
        defer { s1_free_string(pointer) }
        let result = Data(String(cString: pointer).utf8)
        let object = try JSONSerialization.jsonObject(with: result) as? [String: Any]
        guard object?["ok"] as? Bool == true, object?["apiVersion"] as? Int == 1 else {
            throw PrintFailure(object?["error"] as? String ?? "Unsupported Rust result")
        }
        return result
    }
    static func build(_ pages: [NativePage], options: PrintOptions) throws -> PrintJob {
        struct Request: Encodable { let op = "build"; let pages: [NativePage]; let options: PrintOptions }
        return try JSONDecoder().decode(PrintJob.self, from: call(JSONEncoder().encode(Request(pages: pages, options: options))))
    }
    static func ready(_ raw: UInt8) throws {
        let data = try call(JSONSerialization.data(withJSONObject: ["op": "status", "raw": Int(raw)]))
        let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        guard result["ready"] as? Bool == true, result["printing"] as? Bool == false else {
            throw PrintFailure(result["description"] as? String ?? "Printer is not ready")
        }
    }
    static func previewTiles(_ preview: PrintJob.Preview) throws -> [UIImage] {
        guard preview.width == 384, preview.height > 0, preview.rows.count == preview.height * 48 else { throw PrintFailure("Invalid print preview") }
        return try stride(from: 0, to: preview.height, by: 1024).map { top in
            let height = min(1024, preview.height - top)
            var pixels = [UInt8](repeating: 255, count: 384 * height)
            for index in pixels.indices {
                let bit = top * 384 + index
                if preview.rows[bit / 8] & (0x80 >> (bit % 8)) != 0 { pixels[index] = 0 }
            }
            guard let provider = CGDataProvider(data: Data(pixels) as CFData), let image = CGImage(width: 384, height: height,
                bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: 384, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw PrintFailure("Cannot display print preview") }
            return UIImage(cgImage: image)
        }
    }
}
enum DocumentRenderer {
    static func render(_ urls: [URL], maximumPixels: Int = NativeCore.maximumPixels) throws -> [NativePage] {
        var pages: [NativePage] = []
        var total = 0
        for url in urls {
            try Task.checkCancellation()
            let prefix = try FileHandle(forReadingFrom: url)
            let magic = try prefix.read(upToCount: 5)
            try prefix.close()
            if magic == Data("%PDF-".utf8) {
                guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0,
                      pages.count + document.numberOfPages <= 100 else { throw PrintFailure("Invalid PDF or more than 100 pages") }
                for index in 1...document.numberOfPages {
                    try Task.checkCancellation()
                    guard let page = document.page(at: index) else { throw PrintFailure("Cannot read PDF page") }
                    let rect = page.getBoxRect(.cropBox)
                    let rotation = ((page.rotationAngle % 360) + 360) % 360
                    let sideways = rotation == 90 || rotation == 270
                    let naturalWidth = sideways ? rect.height : rect.width
                    let naturalHeight = sideways ? rect.width : rect.height
                    guard naturalWidth > 0, naturalHeight > 0, naturalHeight / naturalWidth <= 200 else { throw PrintFailure("Invalid PDF dimensions") }
                    let scale = 768 / naturalWidth
                    let height = max(1, Int((scale * naturalHeight).rounded()))
                    total += height * 768
                    guard total <= maximumPixels else { throw pixelLimitFailure(maximumPixels) }
                    pages.append(try gray(width: 768, height: height) { context in
                        // getDrawingTransform does not enlarge a small page to a larger
                        // destination. Apply supersampling explicitly before rasterizing.
                        context.scaleBy(x: scale, y: scale)
                        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: naturalWidth, height: naturalHeight), rotate: 0, preserveAspectRatio: true))
                        context.drawPDFPage(page)
                    })
                }
            } else {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2048
                ] as CFDictionary) else { throw PrintFailure("Unsupported or corrupt image") }
                total += image.width * image.height
                guard pages.count < 100 else { throw PrintFailure("Documents exceed 100 pages") }
                guard total <= maximumPixels else { throw pixelLimitFailure(maximumPixels) }
                pages.append(try gray(width: image.width, height: image.height) { $0.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)) })
            }
        }
        return pages
    }
    private static func pixelLimitFailure(_ maximumPixels: Int) -> PrintFailure {
        PrintFailure(maximumPixels < NativeCore.maximumPixels
            ? "This document is too large to prepare in the share sheet. Open S1Print to print the saved document."
            : "Documents exceed 32 Mi pixels")
    }
    private static func gray(width: Int, height: Int, draw: (CGContext) -> Void) throws -> NativePage {
        var bytes = [UInt8](repeating: 255, count: width * height)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw PrintFailure("Cannot render document") }
            context.setFillColor(gray: 1, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            draw(context)
        }
        return NativePage(width: width, height: height, pixels: Data(bytes))
    }
}
