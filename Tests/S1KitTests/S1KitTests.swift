import XCTest
@testable import S1Kit

final class S1KitTests: XCTestCase {
    /// One URF page, 4 px wide, 3 rows: a repeated black row (repeat byte 1), then a literal row.
    func testDecodesURFWithLineRepeatAndLiterals() throws {
        var d = Data("UNIRAST\0".utf8)
        d.append(contentsOf: [0, 0, 0, 1])                       // page count
        var header = [UInt8](repeating: 0, count: 32)
        header[0] = 8; header[1] = 1                               // 8 bpp gray
        header[15] = 4; header[19] = 3; header[23] = 203           // width, height, dpi
        d.append(contentsOf: header)
        d.append(contentsOf: [1, 3, 0x00])                         // 2 rows of 4 black pixels
        d.append(contentsOf: [0, 0xFD, 0x00, 0xFF, 0x00, 0xFF])    // literal: black white black white
        let pages = try RasterDecoder.decode(d)
        XCTAssertEqual(pages.count, 1)
        XCTAssertEqual(pages[0].pixels, [0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 0, 255])
    }

    func testFillRestOfLineIsWhite() throws {
        let bytes: [UInt8] = [0, 0x00, 0x00, 128]                  // one black pixel, rest white
        let (page, _) = try RasterDecoder.decodeBitmap(bytes, at: 0, width: 5, height: 1, dpi: 203, kind: .gray8)
        XCTAssertEqual(page.pixels, [0, 255, 255, 255, 255])
    }

    func testTrimsBlankRowsAtBothEnds() {
        var page = GrayPage(width: 2, height: 6)
        page[0, 3] = 0
        let trimmed = page.trimmingVertical()
        XCTAssertEqual(trimmed.height, 1)
        XCTAssertEqual(trimmed.pixels, [0, 255])
    }

    func testCapsBlankRuns() {
        var page = GrayPage(width: 1, height: 100)
        page[0, 0] = 0
        page[0, 99] = 0
        XCTAssertEqual(page.collapsingBlankRuns(maxRows: 10).height, 12)
    }

    func testJobFramesRasterBetweenStartAndStop() {
        let page = GrayPage(width: 384, height: 300, fill: 0)
        let chunks = S1JobBuilder.build(pages: [page], options: PrintOptions())
        XCTAssertEqual(chunks[2], S1Command.enable)
        XCTAssertEqual(chunks.last, S1Command.stop)
        let raster = chunks.filter { $0.starts(with: [0x1D, 0x76, 0x30]) }
        XCTAssertEqual(raster.count, 2)                            // 255 + 45 rows
        XCTAssertEqual(raster[0].count, 8 + 255 * 48)
    }
}
