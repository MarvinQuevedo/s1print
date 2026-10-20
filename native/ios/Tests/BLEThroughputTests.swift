import XCTest
import CoreBluetooth
@testable import S1Print

final class SendWindowTests: XCTestCase {
    private func fill(_ w: inout SendWindow, at t: TimeInterval = 0) {
        for _ in 0..<w.window { XCTAssertEqual(w.next(at: t, canSend: true), .go); w.noteSent(at: t) }
        // The send loop asks again right away; that is when the window is seen to be full.
        _ = w.next(at: t, canSend: true)
    }

    func testNeverExceedsWindowAndResumesAfterNotification() {
        var w = SendWindow(window: 4, silenceTimeout: 2, fallbackInterval: 0.05)
        fill(&w)
        XCTAssertEqual(w.inFlight, 4)
        guard case .wait(let timeout?) = w.next(at: 0.1, canSend: true) else { return XCTFail("Expected a timed wait") }
        XCTAssertEqual(timeout, 1.9, accuracy: 0.001)
        w.noteNotification(at: 0.2)
        XCTAssertEqual(w.inFlight, 3)
        XCTAssertEqual(w.next(at: 0.2, canSend: true), .go)
        w.noteSent(at: 0.2)
        XCTAssertEqual(w.inFlight, 4)
        guard case .wait = w.next(at: 0.3, canSend: true) else { return XCTFail("Window should be full again") }
    }

    func testCannotSendWaitsForExternalEvent() {
        var w = SendWindow()
        XCTAssertEqual(w.next(at: 0, canSend: false), .wait(timeout: nil))
    }

    func testSilenceFallbackPacesOnePacketPerInterval() {
        var w = SendWindow(window: 4, silenceTimeout: 2, fallbackInterval: 0.05)
        fill(&w)
        XCTAssertEqual(w.next(at: 2.0, canSend: true), .go)
        w.noteSent(at: 2.0)
        guard case .wait(let t?) = w.next(at: 2.02, canSend: true) else { return XCTFail("Fallback must pace") }
        XCTAssertEqual(t, 0.03, accuracy: 0.001)
        XCTAssertEqual(w.next(at: 2.06, canSend: true), .go)
        w.noteSent(at: 2.06)
        XCTAssertEqual(w.inFlight, 6)
        // Still gated by Core Bluetooth even in fallback.
        XCTAssertEqual(w.next(at: 2.2, canSend: false), .wait(timeout: nil))
    }

    func testNotificationAfterFallbackRestoresNormalWindow() {
        var w = SendWindow(window: 4, silenceTimeout: 2, fallbackInterval: 0.05)
        fill(&w)
        for i in 0..<3 { w.noteSent(at: 2.0 + Double(i) * 0.05) }
        XCTAssertEqual(w.inFlight, 7)
        w.noteNotification(at: 2.3)
        XCTAssertEqual(w.inFlight, 3, "clamped to window - 1")
        XCTAssertEqual(w.next(at: 2.3, canSend: true), .go)
        w.noteSent(at: 2.3)
        guard case .wait(let t?) = w.next(at: 2.31, canSend: true) else { return XCTFail("Normal window must apply again") }
        XCTAssertGreaterThan(t, 1.0, "fresh notification restarts the silence clock")
    }

    func testSilenceClockStartsWhenWindowFilledNotAtStaleNotification() {
        var w = SendWindow(window: 2, silenceTimeout: 2, fallbackInterval: 0.05)
        w.noteSent(at: 0); w.noteNotification(at: 0.1)
        // Long idle gap, then the window fills at t=100.
        w.noteSent(at: 100); w.noteSent(at: 100)
        _ = w.next(at: 100, canSend: true)      // the loop sees the full window at once
        guard case .wait(let t?) = w.next(at: 100.5, canSend: true) else { return XCTFail("Stale notification must not trigger fallback") }
        XCTAssertEqual(t, 1.5, accuracy: 0.001)
        XCTAssertEqual(w.next(at: 102.0, canSend: true), .go)
    }

    func testSilenceUsesLaterOfNotificationAndFull() {
        var w = SendWindow(window: 2, silenceTimeout: 2, fallbackInterval: 0.05)
        w.noteSent(at: 0); w.noteSent(at: 0)
        _ = w.next(at: 0, canSend: true)       // full since 0
        w.noteNotification(at: 1.0)             // frees one, resets the clock
        w.noteSent(at: 1.0)
        _ = w.next(at: 1.0, canSend: true)
        guard case .wait(let t?) = w.next(at: 2.5, canSend: true) else { return XCTFail() }
        XCTAssertEqual(t, 0.5, accuracy: 0.001)  // 2 - (2.5 - 1.0)
    }

    func testDrain() {
        var w = SendWindow(window: 4, silenceTimeout: 2, fallbackInterval: 0.05)
        XCTAssertEqual(w.drain(at: 0), .go)
        w.noteSent(at: 0); w.noteSent(at: 0.5)
        guard case .wait(let t?) = w.drain(at: 1.0) else { return XCTFail("Must wait while un-notified") }
        XCTAssertEqual(t, 1.5, accuracy: 0.001)
        w.noteNotification(at: 1.0)
        XCTAssertEqual(w.inFlight, 1)
        guard case .wait = w.drain(at: 1.5) else { return XCTFail("One packet still outstanding") }
        w.noteNotification(at: 1.6)
        XCTAssertEqual(w.drain(at: 1.6), .go)
    }

    func testDrainGivesUpAfterSilence() {
        var w = SendWindow(window: 4, silenceTimeout: 2, fallbackInterval: 0.05)
        w.noteSent(at: 0)
        XCTAssertEqual(w.drain(at: 2.0), .go)
    }

    func testNotificationNeverGoesNegative() {
        var w = SendWindow()
        w.noteNotification(at: 0); w.noteNotification(at: 1)
        XCTAssertEqual(w.inFlight, 0)
    }
}

@MainActor private final class CompletionChannel: PrintChannel {
    var replies: [Data]
    var writes: [Data] = []
    var settled = 0
    init(replies: [Data]) { self.replies = replies }
    func discardReplies() {}
    func send(_ data: Data) async throws { writes.append(data) }
    func settleInFlight() async throws { settled += 1 }
    func response(seconds: Double, predicate: @escaping (Data) -> Bool) async throws -> Data {
        guard !replies.isEmpty else { throw PrintFailure("Simulated timeout") }
        let data = replies.removeFirst()
        guard predicate(data) else { throw PrintFailure("Unexpected response") }
        return data
    }
}

@MainActor final class PrintCompletionTests: XCTestCase {
    func testIsCompletion() {
        XCTAssertTrue(PrintExchange.isCompletion(Data("OK".utf8)))
        XCTAssertTrue(PrintExchange.isCompletion(Data([0x00, 0x4F, 0x4B, 0x01])))
        XCTAssertTrue(PrintExchange.isCompletion(Data([0xAA])))
        XCTAssertFalse(PrintExchange.isCompletion(Data([0xAA, 0xAA])))
        XCTAssertFalse(PrintExchange.isCompletion(Data([0xAA, 0x00])))
        XCTAssertFalse(PrintExchange.isCompletion(Data([0x01, 0x02])))
        XCTAssertFalse(PrintExchange.isCompletion(Data()))
    }

    private func job() throws -> PrintJob {
        try NativeCore.build([NativePage(width: 384, height: 3, pixels: Data(repeating: 0, count: 1152))], options: PrintOptions())
    }

    @MainActor func testSequenceCompletesOnAAStopReplyAndSettlesBeforeStop() async throws {
        let job = try job()
        let channel = CompletionChannel(replies: [Data([0]), Data("OK".utf8), Data([0xAA])])
        try await PrintExchange.run(job, channel: channel) { _ in }
        XCTAssertEqual(channel.writes, [Data([0x10, 0xff, 0x40])] + job.chunks)
        XCTAssertEqual(channel.settled, 1)
        XCTAssertTrue(channel.replies.isEmpty)
    }

    @MainActor func testSilenceAfterStopStillFails() async throws {
        let job = try job()
        let channel = CompletionChannel(replies: [Data([0]), Data("OK".utf8)])
        do { try await PrintExchange.run(job, channel: channel) { _ in }; XCTFail("Accepted silence") }
        catch { XCTAssertEqual(channel.writes.filter { $0 == job.chunks.last }.count, 1) }
    }

    @MainActor func testUnrelatedStopReplyFails() async throws {
        let channel = CompletionChannel(replies: [Data([0]), Data("OK".utf8), Data([0x01, 0x02])])
        do { try await PrintExchange.run(job(), channel: channel) { _ in }; XCTFail("Accepted unrelated reply") }
        catch {}
    }
}

final class NotificationSourceTests: XCTestCase {
    func testFF03IsAFlowSourceNotAReplySource() {
        let p = BLEUARTProfile.ff00
        XCTAssertTrue(p.isReplySource(CBUUID(string: "FF01")))
        XCTAssertFalse(p.isReplySource(CBUUID(string: "FF03")))
        XCTAssertTrue(p.isFlowSource(CBUUID(string: "FF03")))
        XCTAssertTrue(p.isFlowSource(CBUUID(string: "0000FF03-0000-1000-8000-00805F9B34FB")))
        XCTAssertFalse(p.isFlowSource(CBUUID(string: "FF01")))
        XCTAssertFalse(p.isReplySource(CBUUID(string: "FF02")))
        XCTAssertFalse(p.isFlowSource(CBUUID(string: "FF02")))
    }

    func testUART18F0HasNoFlowSource() {
        let p = BLEUARTProfile.uart18f0
        XCTAssertTrue(p.isReplySource(CBUUID(string: "2AF0")))
        XCTAssertFalse(p.isFlowSource(CBUUID(string: "FF03")))
        XCTAssertFalse(p.isReplySource(CBUUID(string: "FF03")))
        XCTAssertFalse(p.isReplySource(CBUUID(string: "2AF1")))
    }
}

final class FlowControlTests: XCTestCase {
    func testCreditGrantsAreCumulative() {
        var f = FlowControl()
        XCTAssertFalse(f.creditsAnnounced)
        XCTAssertEqual(f.apply(Data([0x01, 0x05])), .credits(5))
        XCTAssertEqual(f.credits, 5)
        XCTAssertTrue(f.creditsAnnounced)
        f.apply(Data([0x01, 0x03]))
        XCTAssertEqual(f.credits, 8)
    }

    func testMaxPayloadIsLittleEndian() {
        var f = FlowControl()
        XCTAssertEqual(f.apply(Data([0x02, 0xC8, 0x00])), .maxPayload(200))
        XCTAssertEqual(f.maxPayload, 200)
        f.apply(Data([0x02, 0x00, 0x01]))
        XCTAssertEqual(f.maxPayload, 256)
        XCTAssertFalse(f.creditsAnnounced)
    }

    func testMalformedShortAndUnknownMessagesAreIgnored() {
        var f = FlowControl()
        for bytes: [UInt8] in [[], [0x01], [0x02], [0x02, 0xC8], [0x01, 0x05, 0x00], [0x02, 0xC8, 0x00, 0x00],
                               [0x03, 0x01], [0xAA], [0x00, 0x05], [0x02, 0x00, 0x00]] {
            XCTAssertEqual(f.apply(Data(bytes)), .ignored, "\(bytes)")
        }
        XCTAssertEqual(f, FlowControl())
    }

    func testGateNeverSendsWithZeroCreditsAndResumesAfterGrant() {
        var f = FlowControl()
        XCTAssertEqual(f.next(canSend: true), .wait(timeout: nil))
        XCTAssertFalse(f.consume())
        f.apply(Data([0x01, 0x02]))
        for _ in 0..<2 {
            XCTAssertEqual(f.next(canSend: true), .go)
            XCTAssertTrue(f.consume())
        }
        XCTAssertEqual(f.credits, 0)
        XCTAssertEqual(f.next(canSend: true), .wait(timeout: nil))
        XCTAssertFalse(f.consume())
        XCTAssertEqual(f.credits, 0)
        f.apply(Data([0x01, 0x01]))
        XCTAssertEqual(f.next(canSend: true), .go)
        XCTAssertEqual(f.next(canSend: false), .wait(timeout: nil), "Core Bluetooth readiness still gates")
    }

    func testPacketSizeIsCappedByAnnouncedPayload() {
        var f = FlowControl()
        XCTAssertEqual(f.packetSize(transportLimit: 237), 237)
        f.apply(Data([0x02, 0xC8, 0x00]))
        XCTAssertEqual(f.packetSize(transportLimit: 237), 200)
        XCTAssertEqual(f.packetSize(transportLimit: 100), 100)
    }
}

@MainActor final class BLEInboxTests: XCTestCase {
    private let ff01 = CBUUID(string: "FF01"), ff03 = CBUUID(string: "FF03")

    func testFF03NeverReachesTheReplyBufferOrSatisfiesTheStatusRead() {
        var inbox = BLEInbox()
        let profile = BLEUARTProfile.ff00
        XCTAssertEqual(inbox.ingest(Data([0x01, 0x05]), from: ff03, profile: profile), .flow(.credits(5)))
        XCTAssertEqual(inbox.ingest(Data([0x02, 0xC8, 0x00]), from: ff03, profile: profile), .flow(.maxPayload(200)))
        XCTAssertEqual(inbox.ingest(Data([0xAA]), from: ff03, profile: profile), .flow(.ignored))
        XCTAssertTrue(inbox.received.isEmpty)
        // The status wait predicate from PrintExchange.run.
        XCTAssertFalse(!inbox.received.isEmpty)
        XCTAssertFalse(PrintExchange.isCompletion(inbox.received), "a lone 0xAA on FF03 is not completion")
        XCTAssertEqual(inbox.flow.credits, 5)
        XCTAssertEqual(inbox.flow.maxPayload, 200)
        // FF01 still delivers replies.
        XCTAssertEqual(inbox.ingest(Data([0x00]), from: ff01, profile: profile), .reply)
        XCTAssertEqual(inbox.received, Data([0x00]))
        XCTAssertEqual(inbox.flow.credits, 5, "replies do not touch credits")
    }

    func testClearRepliesKeepsFlowAndResetFlowKeepsReplies() {
        var inbox = BLEInbox()
        _ = inbox.ingest(Data([0x01, 0x04]), from: ff03, profile: .ff00)
        _ = inbox.ingest(Data("OK".utf8), from: ff01, profile: .ff00)
        inbox.clearReplies()
        XCTAssertTrue(inbox.received.isEmpty)
        XCTAssertEqual(inbox.flow.credits, 4)
        inbox.resetFlow()
        XCTAssertEqual(inbox.flow, FlowControl())
    }

    func testUnknownCharacteristicIsIgnored() {
        var inbox = BLEInbox()
        XCTAssertEqual(inbox.ingest(Data([1, 2]), from: CBUUID(string: "FF02"), profile: .ff00), .ignored)
        XCTAssertTrue(inbox.received.isEmpty)
    }
}

@MainActor final class SendStrategySettingTests: XCTestCase {
    private func withDefaults(_ run: (UserDefaults) throws -> Void) throws {
        let name = "S1PrintTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try run(defaults)
    }

    func testDefaultsToWindowed() throws {
        try withDefaults { defaults in
            XCTAssertEqual(PrintSettings(defaults: defaults, legacy: nil).sendStrategy, .windowed)
            XCTAssertEqual(SendStrategy.defaultStrategy, .windowed)
        }
    }

    func testRoundTripsEveryStrategy() throws {
        try withDefaults { defaults in
            for strategy in SendStrategy.allCases {
                PrintSettings(defaults: defaults, legacy: nil).sendStrategy = strategy
                XCTAssertEqual(PrintSettings(defaults: defaults, legacy: nil).sendStrategy, strategy)
            }
        }
    }

    func testUnknownStoredValueFallsBackToDefault() throws {
        try withDefaults { defaults in
            defaults.set("quantum", forKey: PrintSettings.sendStrategyKey)
            XCTAssertEqual(PrintSettings(defaults: defaults, legacy: nil).sendStrategy, .windowed)
        }
    }
}

final class BLETraceTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testHexCapsAtThirtyTwoBytes() {
        XCTAssertEqual(BLETrace.hex(Data([0x0A, 0xFF])), "0A FF")
        XCTAssertEqual(BLETrace.hex(Data(repeating: 1, count: 32)).split(separator: " ").count, 32)
        let long = BLETrace.hex(Data(repeating: 0xAB, count: 40))
        XCTAssertTrue(long.hasSuffix("…(+8 more)"))
        XCTAssertEqual(long.components(separatedBy: "AB").count - 1, 32)
    }

    func testAppendTrimsAtCapKeepingNewestWholeLines() throws {
        let url = directory.appendingPathComponent("log.txt")
        let line = String(repeating: "x", count: 100)
        for i in 0..<800 { BLETrace.append("\(i) \(line)", to: url) }   // ~ 100 KB through the cap
        let data = try Data(contentsOf: url)
        XCTAssertLessThanOrEqual(data.count, BLETrace.capBytes + 256)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let lines = text.split(separator: "\n")
        XCTAssertTrue(lines.last!.contains("799 "), "newest content kept")
        for l in lines { XCTAssertTrue(l.hasSuffix(line), "whole lines only: \(l.prefix(40))") }
        XCTAssertFalse(text.contains(" 0 xxx"), "oldest content dropped")
    }

    func testNotificationLineHasUUIDAndHex() {
        let text = BLETrace.notification(from: "FF03", Data([0xAA]))
        XCTAssertTrue(text.contains("FF03"))
        XCTAssertTrue(text.contains("AA"))
        XCTAssertTrue(text.contains("1 bytes"))
    }
}
