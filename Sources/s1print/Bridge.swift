import AppKit
import Foundation
import ServiceManagement

/// Menu-bar app that publishes the S1 as a driverless (IPP Everywhere / AirPrint)
/// printer on this Mac. It runs Apple's own `ippeveprinter`, which hands every
/// job to this same executable; because the job runs as our child process,
/// macOS attributes the Bluetooth access to this app's permission.
final class Bridge: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let queueName = "S1_Bluetooth"

    private var statusItem: NSStatusItem!
    private var server: Process?
    private var stopping = false
    private let stateItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")

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
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Print Test Page", action: #selector(testPage), keyEquivalent: "t").target = self
        menu.addItem(withTitle: "Add to macOS Printers", action: #selector(addQueue), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Printer Web Page", action: #selector(openWeb), keyEquivalent: "").target = self
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "About S1Print", action: #selector(about), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit S1Print", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        startServer()
        if !queueExists() { addQueue() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if #available(macOS 13.0, *) { loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off }
        stateItem.title = server?.isRunning == true
            ? "Printer “\(Settings.load().serviceName)” is online"
            : "The print server is not running"
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
        if let icon = Bundle.main.url(forResource: "printer-icon", withExtension: "png") { args += ["-i", icon.path] }
        args.append(settings.serviceName)
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

    private func queueExists() -> Bool {
        run("/usr/bin/lpstat", ["-p", Bridge.queueName]) == 0
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

    @objc private func addQueue() {
        // Give the server a moment to start answering before CUPS asks for its attributes.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            let ok = run("/usr/sbin/lpadmin", ["-p", Bridge.queueName, "-E", "-v", printerURI, "-m", "everywhere",
                                                "-D", Settings.load().serviceName, "-L", "Bluetooth"]) == 0
            // CUPS would otherwise default to the smallest label and cut receipts to 30 mm.
            if ok {
                self.run("/usr/sbin/lpadmin", ["-p", Bridge.queueName, "-o", "PageSize=58x600mm.Borderless",
                                               "-o", "media=\(MediaSize.all[0].name)"])
            }
            DispatchQueue.main.async {
                self.stateItem.title = ok ? "Added as “\(Settings.load().serviceName)”" : "Could not add the printer"
            }
        }
    }

    @objc private func testPage() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        p.arguments = ["test"]
        p.terminationHandler = { proc in
            DispatchQueue.main.async {
                self.stateItem.title = proc.terminationStatus == 0 ? "Test page sent" : "Test failed: is the printer on?"
            }
        }
        try? p.run()
    }

    @objc private func openWeb() {
        NSWorkspace.shared.open(URL(string: "http://localhost:\(Settings.load().ippPort)/")!)
    }

    @objc private func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            stateItem.title = "Could not change the login item"
        }
    }

    @objc private func about() {
        let credits = NSMutableAttributedString(string: "Open-source driver for the Luck Jingle S1 Bluetooth thermal printer.\n\nDeveloped by Marvin Quevedo\n")
        let link = "github.com/MarvinQuevedo/s1print"
        credits.append(NSAttributedString(string: link, attributes: [.link: URL(string: "https://\(link)")!]))
        credits.append(NSAttributedString(string: "\n\nMIT License. Not affiliated with Luck Jingle."))
        credits.addAttribute(.font, value: NSFont.systemFont(ofSize: 11), range: NSRange(location: 0, length: credits.length))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
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
