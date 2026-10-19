import AppKit
import IOBluetooth
import SwiftUI

/// State shared by the menu and the Settings window. The bridge owns it and
/// supplies the actions; the window only reads and edits it.
final class AppModel: ObservableObject {
    struct PairedPrinter: Hashable {
        let name: String
        let address: String
    }

    @Published var settings = Settings.load()
    @Published var printerTitle = "Checking the printer…"
    @Published var printerDetail = ""
    @Published var printerReachable: Bool?
    @Published var queueInstalled = false
    @Published var queueBusy = false
    @Published var openAtLogin = false
    @Published var pairedPrinters: [PairedPrinter] = []

    var printTestPage: () -> Void = {}
    var setQueueInstalled: (Bool) -> Void = { _ in }
    var setOpenAtLogin: (Bool) -> Void = { _ in }
    var refreshPrinter: () -> Void = {}
    /// Called after a change that needs the print server restarted (name, sharing).
    var serverSettingsChanged: (_ old: Settings) -> Void = { _ in }

    func reloadPairedPrinters() {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        pairedPrinters = paired.compactMap { d in
            guard let name = d.name, let address = d.addressString,
                  BluetoothTransport.defaultNamePrefixes.contains(where: { name.hasPrefix($0) }) else { return nil }
            return PairedPrinter(name: name, address: address)
        }
    }

    /// Saves a change; restarts the server only for the settings it reads at launch.
    func update(_ change: (inout Settings) -> Void) {
        let old = settings
        var s = settings
        change(&s)
        guard s != old else { return }
        settings = s
        s.save()
        if s.serviceName != old.serviceName || s.shareOnNetwork != old.shareOnNetwork || s.ippPort != old.ippPort {
            serverSettingsChanged(old)
        }
    }
}

enum SettingsWindow {
    private static var window: NSWindow?

    static func show(model: AppModel) {
        model.reloadPairedPrinters()
        model.refreshPrinter()
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            w.title = "S1Print Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        bringToFront(window)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var nameDraft = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Printer") {
                    Picker(selection: Binding(
                        get: { model.settings.address ?? "" },
                        set: { value in model.update { $0.address = value.isEmpty ? nil : value } }
                    )) {
                        Text("Automatic (first S1 found)").tag("")
                        ForEach(model.pairedPrinters, id: \.self) { p in
                            Text(p.name).tag(p.address)
                        }
                    } label: {
                        row("Bluetooth printer", "Paired in System Settings → Bluetooth")
                    }
                    HStack(spacing: 10) {
                        Circle()
                            .fill(model.printerReachable == true ? Color.green : (model.printerReachable == false ? Color.orange : Color.secondary))
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.printerTitle)
                            if !model.printerDetail.isEmpty {
                                Text(model.printerDetail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Print Test Page") { model.printTestPage() }
                    }
                }

                Section("Print quality") {
                    Picker(selection: Binding(
                        get: { model.settings.density },
                        set: { v in model.update { $0.density = v } }
                    )) {
                        Text("Light").tag(0)
                        Text("Medium").tag(1)
                        Text("Dark").tag(2)
                    } label: {
                        row("Darkness", "Darker prints use more battery")
                    }
                    .pickerStyle(.segmented)
                    Toggle(isOn: Binding(
                        get: { model.settings.fitContentWidth },
                        set: { v in model.update { $0.fitContentWidth = v } }
                    )) {
                        row("Fit content to paper width", "Crops empty side margins so receipts from browsers fill the 48 mm head")
                    }
                }

                Section("macOS") {
                    LabeledContent {
                        HStack(spacing: 8) {
                            TextField("", text: $nameDraft)
                                .frame(width: 200)
                                .focused($nameFocused)
                                .onSubmit(commitName)
                            if nameChanged {
                                Button("Rename", action: commitName)
                                    .keyboardShortcut(.defaultAction)
                            }
                        }
                        .onChange(of: nameFocused) { focused in
                            // Apply when the user leaves the field, not only on Return.
                            if !focused { commitName() }
                        }
                    } label: {
                        row("Printer name", "Shown in every print dialog")
                    }
                    Toggle(isOn: Binding(
                        get: { model.queueInstalled },
                        set: { v in model.setQueueInstalled(v) }
                    )) {
                        row("Installed in macOS Printers", "Apps list “\(model.settings.serviceName)” in the print dialog")
                    }
                    .disabled(model.queueBusy)
                    Toggle(isOn: Binding(
                        get: { model.openAtLogin },
                        set: { v in model.setOpenAtLogin(v) }
                    )) {
                        row("Open at login", "The printer only works while S1Print is running")
                    }
                }

                Section("Network") {
                    Toggle(isOn: Binding(
                        get: { model.settings.shareOnNetwork },
                        set: { v in model.update { $0.shareOnNetwork = v } }
                    )) {
                        row("Share on the local network",
                            "Off: only this Mac can print. On: other devices on your Wi-Fi can find and use the printer.")
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text("Changes apply right away").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") {
                    model.update { $0 = Settings() }
                    nameDraft = model.settings.serviceName
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        // A grouped Form scrolls and has no height of its own: without a fixed
        // height the window opened as a 73-pt strip.
        .frame(width: 620, height: 760)
        .onAppear { nameDraft = model.settings.serviceName }
    }

    private var nameChanged: Bool {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name != model.settings.serviceName
    }

    private func commitName() {
        let name = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { nameDraft = model.settings.serviceName; return }
        model.update { $0.serviceName = name }
    }

    private func row(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
