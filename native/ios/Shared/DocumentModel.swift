import Foundation
import UIKit
import Combine

private final class PreparationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    func check() throws { lock.lock(); defer { lock.unlock() }; if stopped { throw CancellationError() } }
}
@MainActor final class AppModel: ObservableObject {
    @Published var batches: [InboxBatch] = []
    @Published var selected: InboxBatch?
    @Published var options = PrintOptions()
    @Published var job: PrintJob?
    @Published var tiles: [UIImage] = []
    @Published var working = false
    @Published var message = "Share a PDF or image to S1Print, or import one below."
    private let queue = DispatchQueue(label: "com.factadte.s1printer.documents", qos: .userInitiated)
    private var generation = 0
    private var token = PreparationToken()
    private let maximumPixels: Int
    private let settings: PrintSettings
    init(maximumPixels: Int = NativeCore.maximumPixels, settings: PrintSettings? = nil) {
        self.maximumPixels = maximumPixels
        self.settings = settings ?? PrintSettings()
        options = self.settings.loadOptions()
    }
    func refresh() {
        do { batches = try Inbox.shared().batches() }
        catch { message = error.localizedDescription }
    }
    func importURLs(_ urls: [URL], preparePreview: Bool = true) {
        generation += 1; let revision = generation
        token.cancel()
        if preparePreview { selected = nil; job = nil }
        working = true; message = "Saving documents…"
        queue.async {
            let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
            defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
            let result = Result { try Inbox.shared().save(urls) }
            DispatchQueue.main.async {
                self.refresh()
                guard revision == self.generation else { return }
                self.working = false
                switch result {
                case .success(let batch):
                    if preparePreview { self.prepare(batch) }
                    else { self.message = "Documents saved. Select them when the current print finishes." }
                case .failure(let error): self.message = error.localizedDescription
                }
            }
        }
    }
    func prepare(_ batch: InboxBatch) {
        generation += 1; let revision = generation
        token.cancel(); token = PreparationToken(); let ticket = token
        selected = batch; job = nil; working = true; message = "Preparing preview…"
        let options = options
        settings.saveOptions(options)
        queue.async {
            let result = Result { () -> (PrintJob, [UIImage]) in
                try ticket.check()
                let inbox = try Inbox.shared()
                let urls = try batch.documents.map { try inbox.file($0, batch: batch) }
                let pages = try DocumentRenderer.render(urls, maximumPixels: self.maximumPixels)
                try ticket.check()
                let job = try NativeCore.build(pages, options: options)
                let tiles = try NativeCore.previewTiles(job.preview)
                try ticket.check()
                return (job, tiles)
            }
            DispatchQueue.main.async {
                guard revision == self.generation else { return }
                self.working = false
                switch result {
                case .success(let result): self.job = result.0; self.tiles = result.1; self.message = "Preview ready"
                case .failure(let error): self.tiles = []; self.message = error.localizedDescription
                }
            }
        }
    }
    func updateOptions() {
        settings.saveOptions(options)
        if let batch = selected { prepare(batch) }
    }
    func restoreSavedOptions() {
        guard !working else { return }
        let saved = settings.loadOptions()
        if saved != options { options = saved }
    }
    func cancelPreparation() {
        generation += 1
        token.cancel()
        working = false
    }
    func remove(_ batch: InboxBatch) {
        do {
            try Inbox.shared().remove(batch)
            if selected?.id == batch.id { generation += 1; token.cancel(); selected = nil; job = nil; tiles = [] }
            refresh()
        } catch { message = error.localizedDescription }
    }
}
