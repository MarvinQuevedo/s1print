import SwiftUI
import CoreBluetooth

struct SharePrintScreen: View {
    @ObservedObject var model: AppModel
    @ObservedObject var printer: BluetoothPrinter
    @ObservedObject var settings: PrintSettings
    let finish: () -> Void
    @State private var printTask: Task<Void, Never>?
    @State private var printed = false
    @State private var starting = false
    @State private var automation = SharePrintAutomation()
    private var automaticPending: Bool {
        settings.automaticSharePrinting && !automation.attempted && !automation.cancelled && !printed
    }

    @State private var choosingPrinter = false
    @State private var printError: String?
    private var printing: Bool { printer.busy || starting }
    private var canPrint: Bool { model.job != nil && printer.selectedDevice != nil && !model.working && !printing && !printed }
    private var statusTitle: String {
        if printed { return "Printed" }
        if printing { return "Printing…" }
        if printError != nil { return "Couldn't print" }
        if model.working { return "Preparing document…" }
        if model.job == nil { return "Document unavailable" }
        if printer.selectedDevice == nil { return printer.isBluetoothReady ? "Finding your printer…" : "Bluetooth unavailable" }
        return "Ready to print"
    }
    private var statusMessage: String {
        if printed { return "Your document was sent to the printer." }
        if let printError { return printError }
        if printing { return printer.message }
        if model.working || model.job == nil { return model.message }
        if printer.selectedDevice == nil {
            if !printer.isBluetoothReady { return printer.message }
            if printer.scanning {
                return settings.savedPrinter == nil ? "Looking for a nearby S1 printer." : "Looking for your saved printer nearby."
            }
            return "Choose a printer or search again."
        }
        return automaticPending ? "Printing will start automatically." : "Using your saved print settings."
    }
    private var optionsSummary: String {
        let density = model.options.density == 0 ? "Light" : model.options.density == 1 ? "Medium" : "Dark"
        return [density, model.options.labelPaper ? "Labels" : "Roll paper",
                model.options.fitContentWidth ? "Fit content" : "Keep margins"].joined(separator: " · ")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 12) {
                        if model.working || printing || (printer.selectedDevice == nil && printer.scanning) {
                            ProgressView().controlSize(.large).padding(8)
                        } else {
                            Image(systemName: printed ? "checkmark.circle.fill" : printError != nil || model.job == nil ? "exclamationmark.circle" : "printer.fill")
                                .font(.system(size: 40)).foregroundStyle(printed ? Color.green : Color.accentColor)
                                .accessibilityHidden(true)
                        }
                        Text(statusTitle).font(.title3.weight(.semibold))
                        Text(statusMessage).font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).textSelection(.enabled)
                        if !printing && !printed && !printer.scanning && printer.selectedDevice == nil {
                            Button("Search again") { printer.startDiscovery() }.disabled(!printer.isBluetoothReady)
                        }
                    }.frame(maxWidth: .infinity).padding(.vertical, 16)

                    if let batch = model.selected {
                        VStack(alignment: .leading, spacing: 10) {
                            Label {
                                Text(batch.documents.count == 1 ? batch.documents[0].name : "\(batch.documents.count) documents")
                                    .font(.subheadline.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            } icon: { Image(systemName: "doc.text").foregroundStyle(Color.accentColor) }
                            Label(printer.selectedDevice?.name ?? settings.savedPrinter?.name ?? "No printer selected", systemImage: "printer")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text(optionsSummary).font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                            .background(.background, in: RoundedRectangle(cornerRadius: 16))
                    }

                    if !printing && !printed {
                        DisclosureGroup(settings.savedPrinter == nil ? "Choose printer" : "Change printer", isExpanded: $choosingPrinter) {
                            VStack(spacing: 0) {
                                ForEach(printer.devices, id: \.identifier) { device in
                                    Button { printer.select(device); choosingPrinter = false } label: {
                                        HStack {
                                            Text(device.name ?? "S1 printer")
                                            Spacer()
                                            if printer.selectedDevice?.identifier == device.identifier { Image(systemName: "checkmark") }
                                        }.padding(.vertical, 12)
                                    }
                                }
                                Button(printer.scanning ? "Stop searching" : "Search again") {
                                    if printer.scanning { printer.stopScan() } else { printer.startDiscovery() }
                                }.padding(.top, 10).disabled(!printer.isBluetoothReady)
                            }
                        }.font(.subheadline).padding(16)
                            .background(.background, in: RoundedRectangle(cornerRadius: 16))
                    }
                    if let job = model.job {
                        DisclosureGroup {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(model.tiles.enumerated()), id: \.offset) { _, tile in
                                    Image(uiImage: tile).resizable().interpolation(.none).scaledToFit()
                                }
                            }.background(.white).padding(.top, 12)
                                .accessibilityLabel("Exact monochrome raster sent to the printer")
                        } label: {
                            HStack {
                                Text("Preview")
                                Spacer()
                                Text("\(job.sourcePages) page(s)").foregroundStyle(.secondary)
                            }
                        }.font(.subheadline).padding(16)
                            .background(.background, in: RoundedRectangle(cornerRadius: 16))
                    }
                }.padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("S1Print").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: finish) { Image(systemName: "xmark") }
                        .accessibilityLabel("Close share panel").disabled(printing)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    if printed {
                        Button("Done", action: finish).buttonStyle(.borderedProminent).controlSize(.large)
                            .frame(maxWidth: .infinity)
                    } else if printing {
                        Button("Cancel printing", role: .destructive) { printTask?.cancel(); printer.cancel() }
                            .buttonStyle(.bordered).controlSize(.large)
                    } else {
                        Button(printError == nil ? "Print" : "Try again", systemImage: "printer") {
                            guard let job = model.job else { return }
                            automation.markManualAttempt()
                            startPrinting(job)
                        }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!canPrint)
                        if automaticPending {
                            Button("Print manually") { automation.cancel() }.font(.subheadline)
                        }
                    }
                    if printing || automaticPending {
                        Text("Keep this panel open.").font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity).padding().background(.bar)
            }
            .onAppear { choosingPrinter = settings.savedPrinter == nil; printer.startDiscovery() }
            .onReceive(model.$job) { job in tryAutomaticPrint(job) }
            .onChange(of: printer.selectedDevice?.identifier) { _, _ in
                if printer.selectedDevice != nil { choosingPrinter = false }
                tryAutomaticPrint(model.job)
            }
            .onDisappear {
                automation.cancel()
                printTask?.cancel()
                if printer.busy { printer.cancel() }
                printer.stopScan()
                printer.disconnectIfIdle()
                model.cancelPreparation()
            }
        }
    }
    private func tryAutomaticPrint(_ job: PrintJob?) {
        guard let job, automation.claim(enabled: settings.automaticSharePrinting,
            savedPrinterID: settings.savedPrinter?.id, detectedPrinterID: printer.selectedDevice?.identifier,
            jobReady: true, busy: printer.busy || starting) else { return }
        startPrinting(job)
    }
    private func startPrinting(_ job: PrintJob) {
        guard let device = printer.selectedDevice, !printer.busy, !starting, !printed else { return }
        starting = true
        printError = nil
        printTask = Task {
            defer { starting = false }
            do {
                try Task.checkCancellation()
                try await printer.printJob(job, to: device)
                printed = true
                printer.disconnectIfIdle()
                printer.message = "Printing completed"
            } catch { printError = error.localizedDescription; model.message = error.localizedDescription }
        }
    }
}
