import Foundation

struct InboxDocument: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let fileName: String
}
struct InboxBatch: Codable, Identifiable, Equatable {
    let id: UUID
    let created: Date
    let documents: [InboxDocument]
}
struct PrintFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A complete batch becomes visible only after every file and the manifest have been copied.
struct Inbox {
    static let group = "group.com.factadte.s1printer"
    static let maximumBytes = 64 * 1024 * 1024
    let root: URL
    init(root: URL) { self.root = root }
    static func shared() throws -> Inbox {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw PrintFailure("Shared document storage is unavailable. Please reinstall S1Print.")
        }
        return Inbox(root: container.appendingPathComponent("Inbox", isDirectory: true))
    }
    func batches() throws -> [InboxBatch] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .compactMap { directory in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
                      let batch = try? JSONDecoder().decode(InboxBatch.self, from: data),
                      batch.id.uuidString == directory.lastPathComponent,
                      !batch.documents.isEmpty, batch.documents.count <= 20,
                      batch.documents.allSatisfy({ $0.fileName == URL(fileURLWithPath: $0.fileName).lastPathComponent }) else { return nil }
                return batch
            }.sorted { $0.created > $1.created }
    }
    func file(_ document: InboxDocument, batch: InboxBatch) throws -> URL {
        guard document.fileName == URL(fileURLWithPath: document.fileName).lastPathComponent else { throw PrintFailure("Invalid inbox file") }
        let url = root.appendingPathComponent(batch.id.uuidString).appendingPathComponent(document.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw PrintFailure("Shared document is no longer available") }
        return url
    }
    func remove(_ batch: InboxBatch) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(batch.id.uuidString))
    }
    /// Source URLs must remain readable for this call. NSItemProvider callers copy temporary files first.
    func save(_ urls: [URL]) throws -> InboxBatch {
        guard (1...20).contains(urls.count) else { throw PrintFailure("Share 1 to 20 files at a time") }
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID()
        let stage = root.appendingPathComponent(".\(id.uuidString)")
        try manager.createDirectory(at: stage, withIntermediateDirectories: false)
        do {
            var total = 0
            let documents = try urls.map { url -> InboxDocument in
                let documentID = UUID()
                let suffix = url.pathExtension.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(10)
                let fileName = documentID.uuidString + (suffix.isEmpty ? "" : ".\(suffix)")
                let target = stage.appendingPathComponent(fileName)
                guard let input = InputStream(url: url), let output = OutputStream(url: target, append: false) else { throw PrintFailure("Cannot open shared file") }
                input.open(); output.open()
                defer { input.close(); output.close() }
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let count = input.read(&buffer, maxLength: buffer.count)
                    guard count >= 0 else { throw input.streamError ?? PrintFailure("Cannot read shared file") }
                    if count == 0 { break }
                    total += count
                    guard total <= Self.maximumBytes else { throw PrintFailure("Shared files exceed 64 MiB") }
                    try buffer.withUnsafeBufferPointer { pointer in
                        var offset = 0
                        while offset < count {
                            let written = output.write(pointer.baseAddress!.advanced(by: offset), maxLength: count - offset)
                            guard written > 0 else { throw output.streamError ?? PrintFailure("Cannot save shared file") }
                            offset += written
                        }
                    }
                }
                return InboxDocument(id: documentID, name: url.lastPathComponent, fileName: fileName)
            }
            let batch = InboxBatch(id: id, created: Date(), documents: documents)
            try JSONEncoder().encode(batch).write(to: stage.appendingPathComponent("manifest.json"), options: .atomic)
            try manager.moveItem(at: stage, to: root.appendingPathComponent(id.uuidString))
            return batch
        } catch {
            try? manager.removeItem(at: stage)
            throw error
        }
    }
}
