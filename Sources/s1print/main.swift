import Foundation
import S1Kit

// One executable, three roles:
//   s1print                      menu-bar bridge (when the app is opened)
//   s1print <file>  + IPP_* env  print command run by ippeveprinter for each job
//   s1print status|test|print …  command line tools

let args = Array(CommandLine.arguments.dropFirst())
let env = ProcessInfo.processInfo.environment
setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
    exit(1)
}

func info(_ message: String) {
    FileHandle.standardError.write(Data("INFO: \(message)\n".utf8))
}

/// Serializes Bluetooth access between concurrent jobs and the CLI.
func withPrinterLock<T>(_ body: () throws -> T) rethrows -> T {
    let path = NSTemporaryDirectory() + "s1print.lock"
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    if fd >= 0 { flock(fd, LOCK_EX) }
    defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
    return try body()
}

func connect(_ address: String?) throws -> BluetoothTransport {
    let t = try BluetoothTransport(address: address ?? env["S1_ADDRESS"] ?? Settings.load().address)
    try t.open()
    return t
}

func ascii(_ d: Data) -> String {
    String(decoding: d.filter { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
}

struct PrinterInfo {
    var model = "", firmware = "", serial = ""
    var battery: Int?
    var status: S1Status?
}

func readInfo(_ t: BluetoothTransport) throws -> PrinterInfo {
    var i = PrinterInfo()
    i.model = ascii(try t.query(S1Command.getModel))
    i.firmware = ascii(try t.query(S1Command.getFirmware))
    i.serial = ascii(try t.query(S1Command.getSerial))
    let b = try t.query(S1Command.getBattery)
    if b.count >= 2 { i.battery = Int(b[b.startIndex + 1]) }
    let s = try t.query(S1Command.getStatus)
    if let first = s.first { i.status = S1Status(raw: first) }
    return i
}

/// Sends a built job, then waits for the printer's "OK".
func send(_ chunks: [Data], over t: BluetoothTransport, bytesPerSecond: Int) throws {
    let total = chunks.reduce(0) { $0 + $1.count }
    var sent = 0, lastPct = -1
    let started = Date()
    for (index, chunk) in chunks.enumerated() {
        // The density command also answers "OK"; only the answer to the final
        // stop command means the job has left the printer's buffer.
        if index == chunks.count - 1 { trace("before stop", t.received, started); t.clearInbox() }
        try t.write(chunk, bytesPerSecond: bytesPerSecond > 0 ? bytesPerSecond : nil)
        sent += chunk.count
        let pct = sent * 100 / max(1, total)
        if pct / 10 != lastPct / 10 { info("sending \(pct)%"); lastPct = pct }
    }
    if t.waitFor(Data("OK".utf8), timeout: 90) {
        trace("stop answered", t.received, started)
    } else {
        info("printer did not confirm the end of the job (no \"OK\")")
    }
    // Closing the channel while the head is still running can cut the last lines.
    BluetoothTransport.pump(1.5)
}

func trace(_ label: String, _ data: Data, _ since: Date) {
    guard env["S1_TRACE"] != nil else { return }
    let hex = data.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
    info(String(format: "%@ at %.2fs: %d bytes [%@]", label, Date().timeIntervalSince(since), data.count, hex))
}

func printPages(_ pages: [GrayPage], options: PrintOptions, address: String?) throws {
    try withPrinterLock {
        let t = try connect(address)
        defer { t.close() }
        if let s = try t.query(S1Command.getStatus).first.map(S1Status.init(raw:)) {
            FileHandle.standardError.write(Data("ATTR: printer-state-reasons=\(s.ippReasons.joined(separator: ","))\n".utf8))
            if s.outOfPaper { throw TransportError.timeout("paper (the printer reports it is out of paper)") }
            if s.coverOpen { throw TransportError.timeout("the cover to close") }
        }
        let chunks = S1JobBuilder.build(pages: pages, options: options)
        let rate = Int(env["S1_RATE"] ?? "") ?? Settings.load().bytesPerSecond
        try send(chunks, over: t, bytesPerSecond: rate)
    }
}

// MARK: Options

func parseOptions(_ argv: inout [String]) -> (PrintOptions, String?) {
    var o = PrintOptions()
    let s = Settings.load()
    o.density = s.density
    var address: String?
    var rest: [String] = []
    var i = 0
    while i < argv.count {
        let a = argv[i]
        func value() -> String { i += 1; return i < argv.count ? argv[i] : "" }
        switch a {
        case "--density", "-d": o.density = Int(value()) ?? o.density
        case "--dither": o.dither = DitherMode(rawValue: value()) ?? .auto
        case "--label": o.labelPaper = true
        case "--trim": o.trimBottom = true
        case "--feed": o.feedAfterPage = Int(value()) ?? o.feedAfterPage
        case "--address", "-a": address = value()
        default: rest.append(a)
        }
        i += 1
    }
    argv = rest
    return (o, address)
}

/// Options for a job coming from ippeveprinter, read from its IPP_* environment.
func ippOptions() -> PrintOptions {
    var o = PrintOptions()
    o.density = Settings.load().density
    let media = (env["IPP_MEDIA"] ?? "") + (env["IPP_MEDIA_COL"] ?? "") + (env["IPP_MEDIA_DEFAULT"] ?? "")
    let mediaName = env["IPP_MEDIA"] ?? env["IPP_MEDIA_DEFAULT"] ?? ""
    let isRoll = mediaName.contains("roll") || mediaName.contains("ticket") ||
        media.contains("y-dimension=60000")
    o.trimBottom = isRoll
    o.feedAfterPage = isRoll ? 80 : 40
    switch env["IPP_PRINT_QUALITY"] {
    case "draft": o.density = 0
    case "high": o.density = 2
    default: break
    }
    if env["IPP_PRINT_CONTENT_OPTIMIZE"] == "photo" { o.dither = .atkinson }
    if env["IPP_PRINT_CONTENT_OPTIMIZE"] == "text" { o.dither = .threshold }
    return o
}

// MARK: Dispatch

var argv = args
if argv.isEmpty || argv.first == "bridge" || argv.first?.hasPrefix("-psn") == true {
    Bridge.run()
}

if env["IPP_JOB_ID"] != nil || (env["CONTENT_TYPE"] != nil && argv.count == 1 && FileManager.default.fileExists(atPath: argv[0])) {
    // Running as the ippeveprinter print command.
    do {
        let url = URL(fileURLWithPath: argv[0])
        // Keep the last job for troubleshooting ("what did macOS send?").
        let keep = Settings.directory.appendingPathComponent("last-job.bin")
        try? FileManager.default.removeItem(at: keep)
        try? FileManager.default.copyItem(at: url, to: keep)
        try? (ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("IPP_") || $0.key == "CONTENT_TYPE" }
            .map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n"))
            .write(to: Settings.directory.appendingPathComponent("last-job.env"), atomically: true, encoding: .utf8)
        let options = ippOptions()
        let pages = try Renderer.pages(from: url, width: options.headWidthDots)
        info("printing \(pages.count) page(s) of \(env["CONTENT_TYPE"] ?? "?")")
        try printPages(pages, options: options, address: nil)
        info("done")
        exit(0)
    } catch {
        fail("\(error)")
    }
}

let command = argv.removeFirst()
let (options, address) = parseOptions(&argv)
do {
    switch command {
    case "status":
        try withPrinterLock {
            let t = try connect(address)
            defer { t.close() }
            let i = try readInfo(t)
            print("printer:  \(t.name) (\(t.address))")
            print("model:    \(i.model)")
            print("firmware: \(i.firmware)")
            print("serial:   \(i.serial)")
            if let b = i.battery { print("battery:  \(b)%") }
            if let s = i.status { print("status:   \(s)") }
        }
    case "test":
        var lines = ["Impresora: S1 por Bluetooth", "Ancho: \(options.headWidthDots) puntos (48 mm)"]
        lines.append(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))
        try printPages([Renderer.testPage(width: options.headWidthDots, lines: lines)], options: options, address: address)
        print("test page sent")
    case "print":
        guard !argv.isEmpty else { fail("usage: s1print print [--density 0-2] [--dither auto|threshold|floyd|atkinson] [--trim] [--label] FILE…") }
        var o = options
        var pages: [GrayPage] = []
        for path in argv {
            let url = URL(fileURLWithPath: path)
            if url.pathExtension.lowercased() == "pdf" { o.trimBottom = true }
            pages += try Renderer.pages(from: url, width: o.headWidthDots)
        }
        try printPages(pages, options: o, address: address)
        print("sent \(pages.count) page(s)")
    case "preview":
        // Writes the exact 1-bit image that would be printed, without touching Bluetooth.
        guard argv.count >= 2 else { fail("usage: s1print preview [--roll] INPUT OUTPUT.png") }
        var o = options
        let input = URL(fileURLWithPath: argv[0])
        if input.pathExtension.lowercased() == "pdf" || RasterDecoder.isRaster((try? Data(contentsOf: input)) ?? Data()) {
            o.trimBottom = true
        }
        let pages = try Renderer.pages(from: input, width: o.headWidthDots)
        try Preview.write(pages: pages, options: o, to: URL(fileURLWithPath: argv[1]))
        print("wrote \(argv[1])")
    case "raw":
        // Debug: send hex bytes and print the answer.
        try withPrinterLock {
            let t = try connect(address)
            defer { t.close() }
            for hex in argv {
                var bytes = [UInt8](); var s = hex[...]
                while s.count >= 2 { bytes.append(UInt8(s.prefix(2), radix: 16) ?? 0); s = s.dropFirst(2) }
                let answer = try t.query(Data(bytes))
                print(hex, "->", answer.map { String(format: "%02x", $0) }.joined(separator: " "), ascii(answer))
            }
        }
    case "help", "--help", "-h":
        print("""
        s1print — open-source driver for the Luck Jingle S1 Bluetooth thermal printer

          s1print                 start the menu-bar bridge (publishes the printer to macOS)
          s1print status          show model, firmware, battery and paper status
          s1print test            print a test page
          s1print print FILE…     print PDF, PNG, JPEG or PWG/URF raster files
                --density 0|1|2   light, medium, dark
                --dither MODE     auto, threshold, floyd, atkinson
                --trim            cut trailing white space (default for PDF)
                --label           advance to the next label gap after each page
          s1print raw HEX…        send raw bytes (debugging)
        """)
    default:
        fail("unknown command \(command); try s1print help")
    }
} catch {
    fail("\(error)")
}
