import AppKit
import SwiftUI

/// The About window: what the app is, who made it, where the code lives.
enum AboutWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: AboutView())
            let w = NSWindow(contentViewController: host)
            w.title = "About S1Print"
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct AboutView: View {
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    private let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    private let repo = URL(string: "https://github.com/MarvinQuevedo/s1print")!

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .padding(.top, 28)
            Text("S1Print")
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 10)
            Text("Version \(version)\(build.isEmpty ? "" : " (\(build))")")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text("Print from any Mac app to the Luck Jingle S1 Bluetooth thermal printer. No vendor driver needed.")
                .font(.body)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)
                .padding(.top, 14)

            VStack(spacing: 4) {
                Text("Developed by")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("Marvin Quevedo", destination: URL(string: "https://github.com/MarvinQuevedo")!)
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(.top, 18)

            HStack(spacing: 10) {
                Link(destination: repo) { Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right") }
                Link(destination: repo.appendingPathComponent("issues/new")) { Label("Report an Issue", systemImage: "exclamationmark.bubble") }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .padding(.top, 16)

            Divider().padding(.top, 20)

            VStack(spacing: 4) {
                Text("Open source under the MIT License.")
                Text("Protocol notes build on fichero-printer by 0xMH.")
                Text("Not affiliated with Luck Jingle or Xiamen Lujiang Technology.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
        }
        .frame(width: 380)
    }
}
