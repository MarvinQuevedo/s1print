import Foundation
import UniformTypeIdentifiers
import CoreGraphics
import ImageIO

/// Shared by the extension and local tests. Provider URLs are copied before their callback ends.
enum ShareImporter {
    static func receive(_ providers: [NSItemProvider], into inbox: Inbox) async throws -> InboxBatch {
        // Web Share can provide its accompanying message as a separate attachment.
        // Ignore text-only providers while preserving document order and atomic imports.
        let documents = providers.filter { provider in
            let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
            return types.isEmpty || !types.allSatisfy { $0.conforms(to: .text) }
        }
        guard (1...20).contains(documents.count) else { throw PrintFailure("Share 1 to 20 PDF or image files. Accompanying text messages are ignored.") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var urls: [URL] = []
        var total = 0
        for provider in documents {
            let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
            let documentType = types.first { $0.conforms(to: .pdf) || $0.conforms(to: .image) }
            let fileURLType = types.first { $0.conforms(to: .fileURL) || $0.conforms(to: .url) }
            let genericType = types.first { $0.conforms(to: .data) && !$0.conforms(to: .text) }
            guard let type = documentType ?? fileURLType ?? genericType else {
                throw PrintFailure("Share the PDF or image file from the source app. Text and web pages cannot be printed here.")
            }
            let directory = temporary.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let remaining = Inbox.maximumBytes - total
            let suggestedName = provider.suggestedName
            let copy: (URL?, Error?) -> Result<URL, Error> = { url, error in
                Result {
                    if let error { throw error }
                    guard let url else { throw PrintFailure("The sharing app did not provide a file") }
                    guard url.isFileURL else { throw PrintFailure("Download the PDF or image first, then share the downloaded file to S1Print.") }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let name = URL(fileURLWithPath: suggestedName ?? url.lastPathComponent).lastPathComponent
                    let target = directory.appendingPathComponent(name.isEmpty ? "document" : name)
                    try copyBounded(url, to: target, limit: remaining)
                    return target
                }
            }
            let copied: URL = try await withCheckedThrowingContinuation { continuation in
                if documentType == nil, fileURLType != nil {
                    provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, error in
                        continuation.resume(with: copy(item as? URL, error))
                    }
                } else {
                    provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                        // Copy while the provider's temporary representation is still valid.
                        continuation.resume(with: copy(url, error))
                    }
                }
            }
            // Generic providers may omit the extension or advertise public.data. Inspect
            // the actual file before publishing it, rather than trusting its name or UTI.
            let url: URL = try await Task.detached {
                let suffix: String
                if CGPDFDocument(copied as CFURL) != nil {
                    suffix = "pdf"
                } else if let image = CGImageSourceCreateWithURL(copied as CFURL, nil),
                          CGImageSourceGetCount(image) > 0,
                          let identifier = CGImageSourceGetType(image),
                          let ext = UTType(identifier as String)?.preferredFilenameExtension {
                    suffix = ext
                } else {
                    throw PrintFailure("The shared file does not contain a readable PDF or image.")
                }
                if copied.pathExtension.lowercased() == suffix { return copied }
                let target = copied.deletingPathExtension().appendingPathExtension(suffix)
                try FileManager.default.moveItem(at: copied, to: target)
                return target
            }.value
            total += try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            urls.append(url)
        }
        let files = urls
        return try await Task.detached { try inbox.save(files) }.value
    }
    private static func copyBounded(_ source: URL, to target: URL, limit: Int) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        var total = 0
        while let chunk = try input.read(upToCount: 65536), !chunk.isEmpty {
            total += chunk.count
            guard total <= limit else { throw PrintFailure("Shared files exceed 64 MiB") }
            try output.write(contentsOf: chunk)
        }
    }
}
