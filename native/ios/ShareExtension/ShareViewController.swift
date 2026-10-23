import UIKit
import SwiftUI

/// Keep the share request open while the user previews and prints the imported batch.
final class ShareViewController: UIViewController {
    private let settings = PrintSettings()
    private lazy var model = AppModel(maximumPixels: 4 * 1024 * 1024, settings: settings)
    private lazy var printer = BluetoothPrinter(settings: settings)
    private var importTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: SharePrintScreen(model: model, printer: printer, settings: settings) { [weak self] in
            self?.finish()
        })
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        importTask = Task { [weak self] in await self?.receive() }
    }

    private func receive() async {
        model.working = true
        model.message = "Importing shared documents…"
        do {
            let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
            let batch = try await ShareImporter.receive(items.flatMap { $0.attachments ?? [] }, into: Inbox.shared())
            try Task.checkCancellation()
            model.prepare(batch)
        } catch {
            model.working = false
            model.message = error.localizedDescription
        }
    }

    private func finish() {
        importTask?.cancel()
        model.cancelPreparation()
        printer.disconnectIfIdle()
        extensionContext?.completeRequest(returningItems: nil)
    }
}
