import Foundation
import Combine

struct SavedPrinter: Codable, Equatable {
    let id: UUID
    let name: String
}

/// Shared app-group preferences used by the app and every share-extension process.
@MainActor final class PrintSettings: ObservableObject {
    @Published private(set) var savedPrinter: SavedPrinter?
    @Published var automaticSharePrinting = false {
        didSet { defaults.set(automaticSharePrinting, forKey: "automaticSharePrinting") }
    }
    @Published var sendStrategy = SendStrategy.defaultStrategy {
        didSet { defaults.set(sendStrategy.rawValue, forKey: Self.sendStrategyKey) }
    }
    static let sendStrategyKey = "bleSendStrategy"
    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil, legacy: UserDefaults? = .standard) {
        self.defaults = defaults ?? UserDefaults(suiteName: Inbox.group) ?? .standard
        if self.defaults.data(forKey: "printOptions") == nil, let previous = legacy?.data(forKey: "printOptions") {
            self.defaults.set(previous, forKey: "printOptions")
        }
        reload()
    }

    func reload() {
        savedPrinter = defaults.data(forKey: "savedPrinter").flatMap { try? JSONDecoder().decode(SavedPrinter.self, from: $0) }
        automaticSharePrinting = defaults.bool(forKey: "automaticSharePrinting")
        sendStrategy = defaults.string(forKey: Self.sendStrategyKey).flatMap(SendStrategy.init(rawValue:)) ?? .defaultStrategy
    }

    func select(id: UUID, name: String) {
        let printer = SavedPrinter(id: id, name: name)
        guard let data = try? JSONEncoder().encode(printer) else { return }
        defaults.set(data, forKey: "savedPrinter")
        savedPrinter = printer
    }

    func forgetPrinter() {
        automaticSharePrinting = false
        defaults.removeObject(forKey: "savedPrinter")
        savedPrinter = nil
    }

    func loadOptions() -> PrintOptions {
        defaults.data(forKey: "printOptions").flatMap { try? JSONDecoder().decode(PrintOptions.self, from: $0) } ?? PrintOptions()
    }

    func saveOptions(_ options: PrintOptions) {
        if let data = try? JSONEncoder().encode(options) { defaults.set(data, forKey: "printOptions") }
    }
}

/// One automatic attempt per share panel, independent of BLE callback ordering.
struct SharePrintAutomation {
    private(set) var attempted = false
    private(set) var cancelled = false

    mutating func claim(enabled: Bool, savedPrinterID: UUID?, detectedPrinterID: UUID?, jobReady: Bool, busy: Bool) -> Bool {
        guard enabled, !attempted, !cancelled, jobReady, !busy,
              let savedPrinterID, savedPrinterID == detectedPrinterID else { return false }
        attempted = true
        return true
    }

    mutating func cancel() { cancelled = true }
    mutating func markManualAttempt() { attempted = true }
}
