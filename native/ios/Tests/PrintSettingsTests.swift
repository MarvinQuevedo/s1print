import XCTest
@testable import S1Print

@MainActor final class PrintSettingsTests: XCTestCase {
    private func withPreferences(_ run: (String, UserDefaults) throws -> Void) throws {
        let name = "S1PrintTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try run(name, defaults)
    }

    func testAppAndShareProcessesRestoreTheSamePrinterAndOptions() throws {
        try withPreferences { name, defaults in
            let app = PrintSettings(defaults: defaults, legacy: nil)
            XCTAssertFalse(app.automaticSharePrinting)
            let id = UUID()
            app.select(id: id, name: "PPS1 saved")
            var options = PrintOptions()
            options.density = 2; options.labelPaper = true; options.fitContentWidth = false
            app.saveOptions(options)
            app.automaticSharePrinting = true

            let share = PrintSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: name)), legacy: nil)
            XCTAssertEqual(share.savedPrinter, SavedPrinter(id: id, name: "PPS1 saved"))
            XCTAssertEqual(share.loadOptions(), options)
            XCTAssertTrue(share.automaticSharePrinting)
            let model = AppModel(settings: share)
            XCTAssertEqual(model.options, options)
        }
    }

    func testChangingOptionsDoesNotOverwriteAutomationOrSelectedPrinter() throws {
        try withPreferences { name, defaults in
            let app = PrintSettings(defaults: defaults, legacy: nil)
            let share = PrintSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: name)), legacy: nil)
            let id = UUID()
            app.select(id: id, name: "S1")
            app.automaticSharePrinting = true
            var options = PrintOptions(); options.density = 0
            share.saveOptions(options)
            app.reload()
            XCTAssertTrue(app.automaticSharePrinting)
            XCTAssertEqual(app.savedPrinter?.id, id)
            XCTAssertEqual(app.loadOptions().density, 0)
        }
    }

    func testForgettingPrinterDisablesAutomaticPrintingAcrossLaunches() throws {
        try withPreferences { name, defaults in
            let app = PrintSettings(defaults: defaults, legacy: nil)
            app.select(id: UUID(), name: "S1")
            app.automaticSharePrinting = true
            app.forgetPrinter()
            let relaunched = PrintSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: name)), legacy: nil)
            XCTAssertNil(relaunched.savedPrinter)
            XCTAssertFalse(relaunched.automaticSharePrinting)
        }
    }

    func testLegacyOptionsAreMigratedWithoutOverwritingSharedSettings() throws {
        try withPreferences { _, shared in
            try withPreferences { _, legacy in
                var old = PrintOptions(); old.density = 2
                legacy.set(try JSONEncoder().encode(old), forKey: "printOptions")
                XCTAssertEqual(PrintSettings(defaults: shared, legacy: legacy).loadOptions(), old)
                var current = PrintOptions(); current.density = 0
                PrintSettings(defaults: shared, legacy: nil).saveOptions(current)
                XCTAssertEqual(PrintSettings(defaults: shared, legacy: legacy).loadOptions(), current)
            }
        }
    }
}

final class SharePrintAutomationTests: XCTestCase {
    func testEitherReadinessOrderTriggersExactlyOneAutomaticAttempt() {
        let id = UUID()
        for printerFirst in [true, false] {
            var gate = SharePrintAutomation()
            XCTAssertFalse(gate.claim(enabled: true, savedPrinterID: id,
                detectedPrinterID: printerFirst ? id : nil, jobReady: !printerFirst, busy: false))
            XCTAssertTrue(gate.claim(enabled: true, savedPrinterID: id, detectedPrinterID: id, jobReady: true, busy: false))
            // A repeated discovery or a rebuilt preview must never resend after success or error.
            XCTAssertFalse(gate.claim(enabled: true, savedPrinterID: id, detectedPrinterID: id, jobReady: true, busy: false))
        }
    }

    func testDisabledMissingMismatchedAndBusyStatesCannotPrint() {
        let id = UUID()
        var gate = SharePrintAutomation()
        XCTAssertFalse(gate.claim(enabled: false, savedPrinterID: id, detectedPrinterID: id, jobReady: true, busy: false))
        XCTAssertFalse(gate.claim(enabled: true, savedPrinterID: nil, detectedPrinterID: id, jobReady: true, busy: false))
        XCTAssertFalse(gate.claim(enabled: true, savedPrinterID: id, detectedPrinterID: UUID(), jobReady: true, busy: false))
        XCTAssertFalse(gate.claim(enabled: true, savedPrinterID: id, detectedPrinterID: id, jobReady: true, busy: true))
        XCTAssertTrue(gate.claim(enabled: true, savedPrinterID: id, detectedPrinterID: id, jobReady: true, busy: false))
    }

    func testCancellationAndManualPrintingPreventLaterAutomaticAttempts() {
        let id = UUID()
        var cancelled = SharePrintAutomation(); cancelled.cancel()
        XCTAssertFalse(cancelled.claim(enabled: true, savedPrinterID: id, detectedPrinterID: id, jobReady: true, busy: false))
        var manual = SharePrintAutomation(); manual.markManualAttempt()
        XCTAssertFalse(manual.claim(enabled: true, savedPrinterID: id, detectedPrinterID: id, jobReady: true, busy: false))
    }
}
