import AppKit
import Foundation
import ServiceManagement
import SwiftUI

/// Menu-bar app that publishes the S1 as a driverless (IPP Everywhere / AirPrint)
/// printer on this Mac. It runs Apple's own `ippeveprinter`, which hands every
/// job to this same executable; because the job runs as our child process,
/// macOS attributes the Bluetooth access to this app's permission.
final class Bridge: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let queueName = "S1_Bluetooth"

    private var statusItem: NSStatusItem!
    private var server: Process?
    private var stopping = false
    private let printerItem = NSMenuItem(title: "Printer: checking…", action: nil, keyEquivalent: "")
    private let stateItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let queueItem = NSMenuItem(title: "Installed in macOS Printers", action: #selector(toggleQueue), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private var queueBusy = false
    private var lastStatusCheck = Date.distantPast
    private var statusCheckRunning = false
    let model = AppModel()

    static func run() -> Never {
        let app = NSApplication.shared
        let delegate = Bridge()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        exit(0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "printer", accessibilityDescription: "S1")
        let menu = NSMenu()
        menu.delegate = self
        printerItem.isEnabled = false
        stateItem.isEnabled = false
        menu.addItem(printerItem)
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Print Test Page", action: #selector(testPage), keyEquivalent: "t").target = self
        queueItem.target = self
        queueItem.toolTip = "Adds or removes the “S1 Bluetooth” printer in macOS"
        menu.addItem(queueItem)
        menu.addItem(withTitle: "Open Printers & Scanners…", action: #selector(openPrinterSettings), keyEquivalent: "").target = self
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "About S1Print", action: #selector(about), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit S1Print", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        wireModel()
        startServer()
        // First run: install the queue so the printer just shows up in print dialogs.
        if !UserDefaults.standard.bool(forKey: "queueOffered") {
            UserDefaults.standard.set(true, forKey: "queueOffered")
            if !queueExists() { setQueue(installed: true, delay: 2) }
        }
    }

    /// Opening the app again (Finder, Spotlight, Launchpad) while it already runs
    /// shows Settings; a menu-bar app has no other window to bring back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    func menuWillOpen(_ menu: NSMenu) {
        if #available(macOS 13.0, *) { loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off }
        stateItem.title = server?.isRunning == true
            ? "Print server: online"
            : "Print server: not running"
        if !queueBusy {
            queueItem.state = queueExists() ? .on : .off
            model.queueInstalled = queueItem.state == .on
            queueItem.title = "Installed in macOS Printers"
        }
        refreshPrinterStatus()
    }

    /// Asks the printer for its state through a child `s1print status`, at most every 30 s.
    private func refreshPrinterStatus() {
        guard !statusCheckRunning, Date().timeIntervalSince(lastStatusCheck) > 30 else { return }
        statusCheckRunning = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        p.arguments = ["status"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.terminationHandler = { [weak self] proc in
            let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            func field(_ key: String) -> String? {
                text.split(separator: "\n").first { $0.hasPrefix(key + ":") }
                    .map { $0.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces) }
            }
            let title: String
            if proc.terminationStatus == 0 {
                let name = field("printer")?.components(separatedBy: " (").first ?? "S1"
                title = [name, field("battery").map { "battery \($0)" }, field("status")]
                    .compactMap { $0 }.joined(separator: " · ")
            } else {
                title = "Printer: off or out of range"
            }
            let detail = [field("model"), field("firmware").map { "firmware \($0)" }].compactMap { $0 }.joined(separator: " · ")
            DispatchQueue.main.async {
                self?.model.printerTitle = proc.terminationStatus == 0 ? title : "Printer off or out of range"
                self?.model.printerDetail = proc.terminationStatus == 0 ? detail : "Turn it on and make sure it is paired"
                self?.model.printerReachable = proc.terminationStatus == 0
                self?.printerItem.title = title
                self?.lastStatusCheck = Date()
                self?.statusCheckRunning = false
            }
        }
        do { try p.run() } catch { statusCheckRunning = false }
    }

    // MARK: ippeveprinter

    private func startServer() {
        let settings = Settings.load()
        let dir = Settings.directory
        let spool = dir.appendingPathComponent("spool", isDirectory: true)
        try? FileManager.default.createDirectory(at: spool, withIntermediateDirectories: true)
        let conf = dir.appendingPathComponent("s1.conf")
        try? ippeveConfig().write(to: conf, atomically: true, encoding: .utf8)
        let log = dir.appendingPathComponent("server.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ippeveprinter")
        var args = ["-p", String(settings.ippPort), "-c", Bundle.main.executablePath ?? CommandLine.arguments[0],
                    "-d", spool.path, "-a", conf.path, "--no-web-forms"]
        // Without sharing, bind to loopback only so other devices cannot print here.
        // and do not advertise it over Bonjour either: an advertised "S1 Bluetooth"
        // also shows up in CUPS as a network destination named like our queue.
        if !settings.shareOnNetwork { args += ["-n", "localhost", "-r", "off"] }
        if let icon = Bundle.main.url(forResource: "printer-icon", withExtension: "png") { args += ["-i", icon.path] }
        // When shared, this Mac would list its own advert next to the local queue
        // under the same name; give the advert the Mac's name to tell them apart.
        args.append(settings.shareOnNetwork
            ? "\(settings.serviceName) @ \(Host.current().localizedName ?? "Mac")"
            : settings.serviceName)
        p.arguments = args
        if let handle = try? FileHandle(forWritingTo: log) { p.standardOutput = handle; p.standardError = handle }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                guard let self, !self.stopping else { return }
                self.startServer()
            }
        }
        do { try p.run(); server = p } catch { stateItem.title = "Could not start ippeveprinter: \(error)" }
    }

    private var printerURI: String { "ipp://localhost:\(Settings.load().ippPort)/ipp/print" }

    /// True only for the local CUPS queue. `lpstat -p NAME` also succeeds for a
    /// Bonjour-discovered printer with that name, which made the menu offer
    /// "remove" for a queue that no longer existed. A local queue has a PPD.
    private func queueExists() -> Bool {
        FileManager.default.fileExists(atPath: "/etc/cups/ppd/\(Bridge.queueName).ppd")
    }

    @discardableResult
    private func run(_ path: String, _ arguments: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus } catch { return -1 }
    }

    // MARK: Menu actions

    @objc private func toggleQueue() {
        guard !queueBusy else { return }
        if queueExists() {
            let alert = NSAlert()
            alert.messageText = "Remove “\(Settings.load().serviceName)” from macOS?"
            alert.informativeText = "Apps will no longer list it in the print dialog. You can add it again from this menu at any time."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            setQueue(installed: false)
        } else {
            setQueue(installed: true)
        }
    }

    /// Adds or removes the CUPS queue, showing progress in the menu and a confirmation bubble.
    private func setQueue(installed: Bool, delay: TimeInterval = 0) {
        queueBusy = true
        model.queueBusy = true
        queueItem.title = installed ? "Adding to macOS Printers…" : "Removing from macOS Printers…"
        let name = Settings.load().serviceName
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            var ok: Bool
            if installed {
                ok = run("/usr/sbin/lpadmin", ["-p", Bridge.queueName, "-E", "-v", printerURI, "-m", "everywhere",
                                               "-D", name, "-L", "Bluetooth"]) == 0
                // CUPS would otherwise default to the smallest label and cut receipts to 30 mm.
                if ok {
                    run("/usr/sbin/lpadmin", ["-p", Bridge.queueName, "-o", "PageSize=58x600mm.Borderless",
                                              "-o", "media=\(MediaSize.all[0].name)"])
                }
            } else {
                ok = run("/usr/sbin/lpadmin", ["-x", Bridge.queueName]) == 0
            }
            let nowInstalled = queueExists()
            DispatchQueue.main.async {
                self.queueBusy = false
                self.queueItem.title = "Installed in macOS Printers"
                self.queueItem.state = nowInstalled ? .on : .off
                self.model.queueInstalled = nowInstalled
                self.model.queueBusy = false
                if ok {
                    self.toast(installed ? "“\(name)” added to your printers" : "“\(name)” removed from your printers",
                               symbol: installed ? "checkmark.circle.fill" : "minus.circle.fill")
                } else {
                    self.toast(installed ? "Could not add the printer" : "Could not remove the printer",
                               symbol: "exclamationmark.triangle.fill")
                }
            }
        }
    }

    /// A small bubble under the menu-bar icon that fades away by itself.
    private func toast(_ message: String, symbol: String) {
        guard let button = statusItem.button else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: ToastView(message: message, symbol: symbol))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { popover.performClose(nil) }
    }

    @objc private func openPrinterSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Print-Scanner-Settings.extension")!)
    }

    @objc private func testPage() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        p.arguments = ["test"]
        p.terminationHandler = { proc in
            DispatchQueue.main.async {
                if proc.terminationStatus == 0 {
                    self.toast("Test page sent", symbol: "checkmark.circle.fill")
                } else {
                    self.toast("Test failed: is the printer on?", symbol: "exclamationmark.triangle.fill")
                }
            }
        }
        try? p.run()
    }

    @objc private func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
            model.openAtLogin = service.status == .enabled
        } catch {
            stateItem.title = "Could not change the login item"
        }
    }

    @objc private func openSettings() {
        model.queueInstalled = queueExists()
        if #available(macOS 13.0, *) { model.openAtLogin = SMAppService.mainApp.status == .enabled }
        lastStatusCheck = .distantPast
        SettingsWindow.show(model: model)
    }

    private func wireModel() {
        model.printTestPage = { [weak self] in self?.testPage() }
        model.refreshPrinter = { [weak self] in self?.refreshPrinterStatus() }
        model.setQueueInstalled = { [weak self] on in
            guard let self, !self.queueBusy, on != self.queueExists() else { return }
            if on { self.setQueue(installed: true) } else { self.toggleQueue() }
        }
        model.setOpenAtLogin = { [weak self] on in
            guard #available(macOS 13.0, *) else { return }
            let service = SMAppService.mainApp
            do { if on { try service.register() } else { try service.unregister() } } catch {
                self?.toast("Could not change the login item", symbol: "exclamationmark.triangle.fill")
            }
            self?.model.openAtLogin = service.status == .enabled
        }
        model.serverSettingsChanged = { [weak self] old in
            guard let self else { return }
            let s = Settings.load()
            if s.serviceName != old.serviceName, self.queueExists() {
                DispatchQueue.global().async { self.run("/usr/sbin/lpadmin", ["-p", Bridge.queueName, "-D", s.serviceName]) }
            }
            // The termination handler starts it again with the new settings.
            self.server?.terminate()
            self.toast(s.shareOnNetwork != old.shareOnNetwork
                ? (s.shareOnNetwork ? "Printer shared on the local network" : "Printer available on this Mac only")
                : "Printer renamed to “\(s.serviceName)”", symbol: "checkmark.circle.fill")
        }
    }

    @objc private func about() {
        AboutWindow.show()
    }

    @objc private func quit() {
        stopping = true
        server?.terminate()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopping = true
        server?.terminate()
    }
}

private struct ToastView: View {
    let message: String
    let symbol: String

    var body: some View {
        Label(message, systemImage: symbol)
            .font(.system(size: 13, weight: .medium))
            .symbolRenderingMode(.multicolor)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }
}
