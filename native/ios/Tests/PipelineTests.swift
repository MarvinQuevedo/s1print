import XCTest
import UIKit
import UniformTypeIdentifiers
import CoreBluetooth
@testable import S1Print

final class BLEUARTProfileTests: XCTestCase {
    func testFF00ServiceAcceptsShortAndFullBluetoothUUIDs() throws {
        for service in ["FF00", "0000FF00-0000-1000-8000-00805F9B34FB"] {
            let profile = try XCTUnwrap(BLEUARTProfile.matching(CBUUID(string: service)))
            XCTAssertEqual(profile, .ff00)
            XCTAssertEqual(profile.writeUUID, CBUUID(string: "0000FF02-0000-1000-8000-00805F9B34FB"))
            XCTAssertEqual(profile.notifyUUID, CBUUID(string: "0000FF01-0000-1000-8000-00805F9B34FB"))
        }
    }

    func test18F0ServiceAcceptsShortAndFullBluetoothUUIDs() throws {
        for service in ["18F0", "000018F0-0000-1000-8000-00805F9B34FB"] {
            let profile = try XCTUnwrap(BLEUARTProfile.matching(CBUUID(string: service)))
            XCTAssertEqual(profile, .uart18f0)
            XCTAssertEqual(profile.writeUUID, CBUUID(string: "00002AF1-0000-1000-8000-00805F9B34FB"))
            XCTAssertEqual(profile.notifyUUID, CBUUID(string: "00002AF0-0000-1000-8000-00805F9B34FB"))
        }
    }

    func testUnsupportedServicesAndSimilarVendorUUIDsAreRejected() {
        for service in ["180F", "0000FF00-1234-1000-8000-00805F9B34FB"] {
            XCTAssertNil(BLEUARTProfile.matching(CBUUID(string: service)))
        }
    }
}

final class PipelineTests: XCTestCase {
    private var directory: URL!
    private var inbox: Inbox!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        inbox = Inbox(root: directory.appendingPathComponent("inbox"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func image() throws -> URL {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 384, height: 100)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 384, height: 100))
            UIColor.black.setFill(); context.fill(CGRect(x: 20, y: 20, width: 300, height: 50))
        }
        let url = directory.appendingPathComponent("sample.png")
        try XCTUnwrap(image.pngData()).write(to: url)
        return url
    }
    private func pdf() throws -> URL {
        let url = directory.appendingPathComponent("sample.pdf")
        try UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 192, height: 120)).writePDF(to: url) { context in
            for _ in 0..<2 {
                context.beginPage(); UIColor.black.setFill(); context.fill(CGRect(x: 20, y: 20, width: 100, height: 40))
            }
        }
        return url
    }
    func testPersistentMixedImportReachesRustAndPreview() throws {
        let batch = try inbox.save([image(), pdf()])
        let loaded = try Inbox(root: inbox.root).batches()
        XCTAssertEqual(loaded, [batch])
        let urls = try batch.documents.map { try inbox.file($0, batch: batch) }
        let pages = try DocumentRenderer.render(urls)
        XCTAssertEqual(pages.count, 3)
        let job = try NativeCore.build(pages, options: PrintOptions())
        XCTAssertEqual(job.sourcePages, 3)
        XCTAssertEqual(job.preview.width, 384)
        XCTAssertEqual(job.preview.rows.count, job.preview.height * 48)
        XCTAssertEqual(job.chunks.last, Data([0x10, 0xff, 0xf1, 0x45]))
        XCTAssertFalse(try NativeCore.previewTiles(job.preview).isEmpty)
        let rasterRows = job.chunks.filter { $0.starts(with: [0x1d, 0x76, 0x30, 0]) }.reduce(into: Data()) { $0.append($1.dropFirst(8)) }
        XCTAssertEqual(job.preview.rows, rasterRows)
    }
    func testSmallPDFIsSupersampledBeforeRasterization() throws {
        let pages = try DocumentRenderer.render([pdf()])
        XCTAssertEqual(pages[0].width, 768)
        XCTAssertEqual(pages[0].height, 480)
        // The 100×40-point rectangle must be 400×160 pixels, rather than a
        // low-resolution 100×40 bitmap later enlarged by Rust's content fitting.
        XCTAssertGreaterThan(pages[0].pixels.filter { $0 < 40 }.count, 50_000)
        XCTAssertLessThan(pages[0].pixels.filter { $0 < 40 }.count, 70_000)
    }
    @MainActor func testSharePreparationBuildsJobWithoutOpeningMainApp() async throws {
        let shared = try Inbox.shared()
        let source = try pdf()
        let provider = NSItemProvider(item: source as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let batch = try await ShareImporter.receive([NSItemProvider(object: "Invoice message" as NSString), provider], into: shared)
        defer { try? shared.remove(batch) }
        let model = AppModel(maximumPixels: 4 * 1024 * 1024)
        model.prepare(batch)
        let deadline = Date().addingTimeInterval(15)
        while model.working && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotNil(model.job, model.message)
        XCTAssertEqual(model.job?.sourcePages, 2)
        XCTAssertFalse(model.tiles.isEmpty)
    }
    @MainActor func testSharePreparationLimitPreservesSavedDocuments() async throws {
        let shared = try Inbox.shared()
        let batch = try shared.save([pdf()])
        defer { try? shared.remove(batch) }
        let model = AppModel(maximumPixels: 1)
        model.prepare(batch)
        let deadline = Date().addingTimeInterval(15)
        while model.working && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNil(model.job)
        XCTAssertTrue(model.message.contains("Open S1Print"), model.message)
        XCTAssertTrue(try shared.batches().contains(batch))
    }
    func testShareProvidersSaveIndependentCopiesInOrder() async throws {
        let sources = try [image(), pdf()]
        let providers = sources.enumerated().map { index, url -> NSItemProvider in
            let provider = NSItemProvider()
            provider.suggestedName = url.lastPathComponent
            provider.registerFileRepresentation(forTypeIdentifier: index == 0 ? UTType.png.identifier : UTType.pdf.identifier, fileOptions: [], visibility: .all) { completion in
                completion(url, false, nil); return nil
            }
            return provider
        }
        let batch = try await ShareImporter.receive(providers, into: inbox)
        for source in sources { try FileManager.default.removeItem(at: source) }
        XCTAssertEqual(batch.documents.map(\.name), ["sample.png", "sample.pdf"])
        XCTAssertEqual(try DocumentRenderer.render(batch.documents.map { try inbox.file($0, batch: batch) }).count, 3)
    }
    func testFailedBatchIsNeverPublished() throws {
        let valid = try image()
        let batch = try inbox.save([valid])
        XCTAssertThrowsError(try inbox.save([valid, directory.appendingPathComponent("missing.pdf")]))
        XCTAssertEqual(try inbox.batches(), [batch])
        XCTAssertThrowsError(try inbox.save(Array(repeating: valid, count: 21)))
    }
    func testUnsupportedShareIsRejected() async throws {
        let provider = NSItemProvider(object: "text is not printable input" as NSString)
        do { _ = try await ShareImporter.receive([provider], into: inbox); XCTFail("Accepted text") }
        catch { XCTAssertTrue(try inbox.batches().isEmpty) }
    }
    func testGenericFileRepresentationsAreRecognizedByContents() async throws {
        let sources = try [pdf(), image()]
        let providers = sources.enumerated().map { index, url -> NSItemProvider in
            let provider = NSItemProvider()
            provider.suggestedName = index == 0 ? "invoice.bin" : "image"
            provider.registerFileRepresentation(forTypeIdentifier: UTType.data.identifier, fileOptions: [], visibility: .all) { completion in
                completion(url, false, nil); return nil
            }
            return provider
        }
        let batch = try await ShareImporter.receive(providers, into: inbox)
        for source in sources { try FileManager.default.removeItem(at: source) }
        XCTAssertEqual(batch.documents.map(\.name), ["invoice.pdf", "image.png"])
        XCTAssertEqual(try DocumentRenderer.render(batch.documents.map { try inbox.file($0, batch: batch) }).count, 3)
    }
    func testFactadteShareImportsPDFAndIgnoresAccompanyingText() async throws {
        let source = try pdf()
        let document = NSItemProvider()
        document.suggestedName = "invoice.pdf"
        document.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { completion in
            completion(source, false, nil); return nil
        }
        let title = NSItemProvider(object: "Electronic invoice" as NSString)
        let message = NSItemProvider(object: "Here is your invoice and its reference number." as NSString)
        for providers in [[title, document, message], [document, message]] {
            let batch = try await ShareImporter.receive(providers, into: inbox)
            XCTAssertEqual(batch.documents.map(\.name), ["invoice.pdf"])
            XCTAssertEqual(try DocumentRenderer.render(batch.documents.map { try inbox.file($0, batch: batch) }).count, 2)
        }
    }
    func testAccompanyingTextDoesNotCountTowardTwentyDocumentLimit() async throws {
        let source = try image()
        let document = NSItemProvider()
        document.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
            completion(source, false, nil); return nil
        }
        let message = NSItemProvider(object: "Shared documents" as NSString)
        let batch = try await ShareImporter.receive([message] + Array(repeating: document, count: 20), into: inbox)
        XCTAssertEqual(batch.documents.count, 20)
    }
    func testLocalFileURLProviderImportsIndependentPDFCopy() async throws {
        let source = try pdf()
        let provider = NSItemProvider(item: source as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let batch = try await ShareImporter.receive([provider], into: inbox)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(batch.documents.first?.name, "sample.pdf")
        XCTAssertEqual(try DocumentRenderer.render(batch.documents.map { try inbox.file($0, batch: batch) }).count, 2)
    }
    func testWebLinkIsRejectedWithoutDownloading() async throws {
        let provider = NSItemProvider(item: NSURL(string: "https://example.invalid/invoice.pdf")!, typeIdentifier: UTType.url.identifier)
        do { _ = try await ShareImporter.receive([provider], into: inbox); XCTFail("Accepted a web link") }
        catch {
            XCTAssertTrue(error.localizedDescription.contains("Download the PDF"))
            XCTAssertTrue(try inbox.batches().isEmpty)
        }
    }
    func testInvalidGenericFileRollsBackWholeShare() async throws {
        let invalid = directory.appendingPathComponent("fake.pdf")
        try Data("This is not a PDF".utf8).write(to: invalid)
        let valid = try pdf()
        let providers = [valid, invalid].map { url -> NSItemProvider in
            let provider = NSItemProvider()
            provider.registerFileRepresentation(forTypeIdentifier: UTType.data.identifier, fileOptions: [], visibility: .all) { completion in
                completion(url, false, nil); return nil
            }
            return provider
        }
        do { _ = try await ShareImporter.receive(providers, into: inbox); XCTFail("Accepted an invalid file") }
        catch { XCTAssertTrue(try inbox.batches().isEmpty) }
    }
    func testRealRustErrorsAndStatusChecks() throws {
        XCTAssertThrowsError(try NativeCore.build([], options: PrintOptions()))
        XCTAssertNoThrow(try NativeCore.ready(0))
        XCTAssertThrowsError(try NativeCore.ready(4))
        let page = NativePage(width: 384, height: 3, pixels: Data(repeating: 0, count: 384 * 3))
        var options = PrintOptions(); options.fitContentWidth = false
        let job = try NativeCore.build([page], options: options)
        let raster = try XCTUnwrap(job.chunks.first { $0.starts(with: [0x1d, 0x76, 0x30, 0]) })
        XCTAssertTrue(raster.dropFirst(8).allSatisfy { $0 == 255 })
    }
    @MainActor func testAppGroupAndForegroundImport() async throws {
        let shared = try Inbox.shared()
        let model = AppModel()
        model.importURLs([try image(), try pdf()])
        let deadline = Date().addingTimeInterval(15)
        while model.working && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        let batch = try XCTUnwrap(model.selected, model.message)
        defer { try? shared.remove(batch) }
        XCTAssertNotNil(model.job, model.message)
        XCTAssertEqual(model.job?.sourcePages, 3)
        XCTAssertTrue(try shared.batches().contains(batch))
    }
    func testAggregateByteLimitRollsBackBatch() throws {
        let url = directory.appendingPathComponent("too-large.pdf")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(Inbox.maximumBytes + 1)); try handle.close()
        XCTAssertThrowsError(try inbox.save([url]))
        XCTAssertTrue(try inbox.batches().isEmpty)
    }
    func testLongPreviewUsesBoundedTiles() throws {
        let preview = PrintJob.Preview(width: 384, height: 20_000, rows: Data(repeating: 255, count: 48 * 20_000))
        let tiles = try NativeCore.previewTiles(preview)
        XCTAssertEqual(tiles.count, 20)
        XCTAssertTrue(tiles.allSatisfy { $0.size.height <= 1024 })
    }
    func testDeleteRemovesOnlySelectedBatch() throws {
        let one = try inbox.save([image()]); let two = try inbox.save([pdf()])
        try inbox.remove(one)
        XCTAssertEqual(try inbox.batches(), [two])
    }
}

@MainActor private final class FakePrinterChannel: PrintChannel {
    var replies: [Data]
    var writes: [Data] = []
    var clears = 0
    var waits: [Double] = []
    init(replies: [Data]) { self.replies = replies }
    func discardReplies() { clears += 1 }
    func send(_ data: Data) async throws { writes.append(data) }
    func response(seconds: Double, predicate: @escaping (Data) -> Bool) async throws -> Data {
        waits.append(seconds)
        guard !replies.isEmpty else { throw PrintFailure("Simulated timeout") }
        let data = replies.removeFirst()
        guard predicate(data) else { throw PrintFailure("Unexpected response") }
        return data
    }
}
final class PrintExchangeTests: XCTestCase {
    private func job() throws -> PrintJob {
        try NativeCore.build([NativePage(width: 384, height: 3, pixels: Data(repeating: 0, count: 1152))], options: PrintOptions())
    }
    @MainActor func testDensityAndFinalAcknowledgmentsAreSeparate() async throws {
        let job = try job()
        let channel = FakePrinterChannel(replies: [Data([0]), Data("OK".utf8), Data("OK".utf8)])
        try await PrintExchange.run(job, channel: channel) { _ in }
        XCTAssertEqual(channel.writes, [Data([0x10, 0xff, 0x40])] + job.chunks)
        XCTAssertEqual(channel.clears, 3)
        XCTAssertEqual(channel.waits, [4, 4, 90])
        XCTAssertTrue(channel.replies.isEmpty)
    }
    @MainActor func testRasterReplyBeforeStopCompletesTheJob() async throws {
        let job = try job()
        let channel = FakePrinterChannel(replies: [Data([0]), Data("OK".utf8), Data("OK".utf8)])
        try await PrintExchange.run(job, channel: channel) { _ in }
        let raster = try XCTUnwrap(job.chunks.lastIndex { $0.starts(with: Data([0x1D, 0x76, 0x30, 0x00])) })
        XCTAssertLessThan(raster, job.chunks.count - 1)
        XCTAssertEqual(channel.writes.last, job.chunks.last)
    }
    @MainActor func testMissingFinalAcknowledgmentNeverRetries() async throws {
        let job = try job()
        let channel = FakePrinterChannel(replies: [Data([0]), Data("OK".utf8)])
        do { try await PrintExchange.run(job, channel: channel) { _ in }; XCTFail("Accepted missing completion") }
        catch { XCTAssertEqual(channel.writes.filter { $0 == job.chunks.last }.count, 1) }
    }
    @MainActor func testOutOfPaperBlocksAllPrintBytes() async throws {
        let channel = FakePrinterChannel(replies: [Data([4])])
        do { try await PrintExchange.run(job(), channel: channel) { _ in }; XCTFail("Printed without paper") }
        catch { XCTAssertEqual(channel.writes, [Data([0x10, 0xff, 0x40])]) }
    }

    func testPrinterErrorRepliesAbortButOtherRepliesDoNot() {
        XCTAssertNotNil(PrintExchange.printerError(Data([0xFF, 0x01])))
        XCTAssertNotNil(PrintExchange.printerError(Data([0xFF, 0x02])))
        XCTAssertNotNil(PrintExchange.printerError(Data([0xFF, 0x13])))
        XCTAssertNotNil(PrintExchange.printerError(Data([0xFF, 0x04])))
        XCTAssertNil(PrintExchange.printerError(Data("OK".utf8)))
        XCTAssertNil(PrintExchange.printerError(Data([0xAA])))
        XCTAssertNil(PrintExchange.printerError(Data([0xFF, 0x01, 0x00])))
    }
}
