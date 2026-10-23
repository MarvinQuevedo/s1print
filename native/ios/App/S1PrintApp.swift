import SwiftUI
import UniformTypeIdentifiers
import CoreBluetooth

/// Simulator-only App Store screenshot mode (`-screenshotScene main|preview|options|about`): shows the
/// connected-printer state the simulator cannot reach. Never compiled into device builds.
enum ScreenshotDemo {
    #if targetEnvironment(simulator)
    static let scene: String? = UserDefaults.standard.string(forKey: "screenshotScene")
    #else
    static let scene: String? = nil
    #endif
    static var active: Bool { scene != nil }
}

@main struct S1PrintApp: App {
    var body: some Scene { WindowGroup { MainScreen() } }
}
struct MainScreen: View {
    @StateObject private var model = AppModel()
    @StateObject private var settings: PrintSettings
    @StateObject private var printer: BluetoothPrinter
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var printTask: Task<Void, Never>?
    @State private var optionsExpanded = ScreenshotDemo.scene == "options"
    @State private var showAbout = ScreenshotDemo.scene == "about"
    init() {
        let settings = PrintSettings()
        _settings = StateObject(wrappedValue: settings)
        _printer = StateObject(wrappedValue: BluetoothPrinter(settings: settings))
    }
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image("AppLogo").resizable().scaledToFit().frame(width: 52, height: 52).accessibilityHidden(true)
                        VStack(alignment: .leading) { Text("S1Print").font(.title2.bold()); Text("Print PDFs and images on your S1.").font(.subheadline).foregroundStyle(.secondary) }
                    }
                    Text(model.message).accessibilityIdentifier("documentStatus")
                    if model.working { ProgressView("Preparing documents") }
                }
                Section("Printer") {
                    if ScreenshotDemo.active {
                        Text("Connected · battery 90% · paper loaded").font(.subheadline)
                        HStack { Text("PPS1_8D2A"); Spacer(); Image(systemName: "checkmark").foregroundStyle(.tint) }
                        Text("Default printer: PPS1_8D2A").font(.caption)
                    } else {
                    Text(printer.message).font(.subheadline)
                    Button(printer.scanning ? "Stop scanning" : "Find BLE printers") {
                        if printer.scanning { printer.stopScan() } else { printer.scan() }
                    }.disabled(printer.busy)
                    ForEach(printer.devices, id: \.identifier) { device in
                        Button { printer.select(device) } label: {
                            HStack { Text(device.name ?? "S1 printer"); Spacer(); if printer.selectedDevice?.identifier == device.identifier { Image(systemName: "checkmark") } }
                        }.disabled(printer.busy)
                    }
                    if let saved = settings.savedPrinter {
                        Text("Default printer: \(saved.name)").font(.caption)
                        if printer.selectedDevice == nil { Text("Waiting for the saved printer to appear nearby.").font(.caption).foregroundStyle(.secondary) }
                        Button("Forget printer", role: .destructive) { printer.forgetSelection() }.disabled(printer.busy)
                    }
                    }
                }
                Section("Printing from other apps") {
                    Toggle("Print automatically from Share", isOn: $settings.automaticSharePrinting)
                        .disabled(settings.savedPrinter == nil || printer.busy)
                    Text("Shared documents use your saved printer and print options. When enabled, printing starts as soon as that printer is found and the document is ready. Otherwise, the Share panel prepares the Print button.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Documents") {
                    Button("Import PDF or images", systemImage: "doc.badge.plus") { importing = true }.disabled(model.working || printer.busy)
                    if model.batches.isEmpty { Text("Documents shared from other apps appear here.").foregroundStyle(.secondary) }
                    ForEach(model.batches) { batch in
                        Button { model.prepare(batch) } label: {
                            VStack(alignment: .leading) {
                                Text(batch.documents.map(\.name).joined(separator: ", ")).lineLimit(2)
                                Text("\(batch.documents.count) file(s) · \(batch.created.formatted())").font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(model.working || printer.busy)
                        .swipeActions { Button("Delete", role: .destructive) { model.remove(batch) }.disabled(printer.busy || model.working) }
                    }
                }
                Section {
                    DisclosureGroup("Print options", isExpanded: $optionsExpanded) {
                        Picker("Density", selection: $model.options.density) { Text("Light").tag(0); Text("Medium").tag(1); Text("Dark").tag(2) }
                        Toggle("Fit to printhead width", isOn: $model.options.fitContentWidth)
                        Toggle("Label paper", isOn: $model.options.labelPaper)
                    }.disabled(printer.busy).id("options")
                    #if DEBUG
                    if !ScreenshotDemo.active {
                    DisclosureGroup("Bluetooth sending (diagnostics)") {
                        Picker("Strategy", selection: $settings.sendStrategy) {
                            ForEach(SendStrategy.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.inline).labelsHidden()
                    }.disabled(printer.busy)
                    }
                    #endif
                }
                if let job = model.job {
                    Section("Monochrome preview") {
                        EmptyView().id("preview")
                        Text("\(job.sourcePages) page(s) · \(job.preview.width) × \(job.preview.height) dots").font(.caption)
                        VStack(spacing: 0) {
                            ForEach(Array(model.tiles.enumerated()), id: \.offset) { _, tile in
                                Image(uiImage: tile).resizable().interpolation(.none).scaledToFit()
                            }
                        }.background(.white).accessibilityLabel("Exact monochrome raster sent to the printer")
                    }
                }
            }
            .onChange(of: model.tiles.count) { _, count in
                if ScreenshotDemo.scene == "preview", count > 0 { proxy.scrollTo("preview", anchor: .top) }
                if ScreenshotDemo.scene == "options", count > 0 { proxy.scrollTo("options", anchor: .center) }
            }
            }
            .navigationTitle("S1Print").navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showAbout) { AboutScreen() }
            .toolbar { NavigationLink { AboutScreen() } label: { Image(systemName: "info.circle").accessibilityLabel("About S1Print") } }
            .safeAreaInset(edge: .bottom) {
                VStack {
                    Text(ScreenshotDemo.active ? "Ready to print on PPS1_8D2A." : printer.message).font(.caption).multilineTextAlignment(.center)
                        .accessibilityIdentifier("printTransportStatus")
                    if printer.busy {
                        ProgressView(); Button("Cancel printing", role: .destructive) { printTask?.cancel(); printer.cancel() }
                    } else if printer.completed {
                        Button("Done", systemImage: "checkmark") { printer.completed = false }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                        Button("Print again", systemImage: "printer") { startPrint() }
                            .disabled(!ScreenshotDemo.active && (model.job == nil || printer.selectedDevice == nil || model.working))
                    } else {
                        Button("Print", systemImage: "printer") { startPrint() }.buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(!ScreenshotDemo.active && (model.job == nil || printer.selectedDevice == nil || model.working))
                        Text(printer.selectedDevice == nil && !ScreenshotDemo.active ? "Waiting for your printer. Select it once to save it." : "Review the preview, then print.").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity).padding().background(.regularMaterial)
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
                switch result { case .success(let urls): model.importURLs(urls); case .failure(let error): model.message = error.localizedDescription }
            }
            .onOpenURL { url in model.importURLs([url], preparePreview: !printer.busy) }
            .onChange(of: model.options) { _, _ in model.updateOptions() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { model.refresh(); settings.reload(); model.restoreSavedOptions(); printer.startDiscovery() }
                else if phase == .background { printer.disconnectIfIdle() }
            }
            .task {
                model.refresh(); printer.startDiscovery()
                if ScreenshotDemo.active, let first = model.batches.first { model.prepare(first) }
            }
        }
    }
}
extension MainScreen {
    private func startPrint() {
        guard let job = model.job, let device = printer.selectedDevice else { return }
        printTask = Task {
            do { try await printer.printJob(job, to: device) }
            catch { model.message = error.localizedDescription }
        }
    }
}
struct AboutScreen: View {
    private var licenseText: String {
        Bundle.main.url(forResource: "LICENSE", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "License unavailable"
    }
    var body: some View {
        Form {
            Section {
                Image("AppLogo").resizable().scaledToFit().frame(width: 96, height: 96).accessibilityHidden(true)
                Text("S1Print").font(.title2)
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))")
                Text("Print PDFs and images to the Luck Jingle S1 Bluetooth thermal printer.")
            }
            Section("Developed by") {
                Link("Marvin Quevedo", destination: URL(string: "https://github.com/MarvinQuevedo")!)
                Link("Source Code", destination: URL(string: "https://github.com/MarvinQuevedo/s1print")!)
                Link("Report an Issue", destination: URL(string: "https://github.com/MarvinQuevedo/s1print/issues/new")!)
                Link("Privacy Policy", destination: URL(string: "https://marvinquevedo.github.io/s1print/privacy.html")!)
            }
            Section("Made by the Facta DTE team") {
                Text("Electronic invoicing for El Salvador: facturas, créditos fiscales and tickets, signed and sent to the Ministerio de Hacienda, ready to print on this printer.")
                Link("factadte.com", destination: URL(string: "https://www.factadte.com")!)
            }
            Section("Credits and license") {
                Link("Protocol notes: fichero-printer by 0xMH", destination: URL(string: "https://github.com/0xMH/fichero-printer")!)
                Text("Not affiliated with Luck Jingle or Xiamen Lujiang Technology.")
                NavigationLink("MIT License") { ScrollView { Text(licenseText).padding().textSelection(.enabled) }.navigationTitle("MIT License") }
            }
        }.navigationTitle("About S1Print")
    }
}
