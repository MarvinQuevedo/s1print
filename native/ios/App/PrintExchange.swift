import Foundation

@MainActor protocol PrintChannel {
    func discardReplies()
    func send(_ data: Data) async throws
    func response(seconds: Double, predicate: @escaping (Data) -> Bool) async throws -> Data
}

/// Protocol sequencing independent of Core Bluetooth, exercised with a local in-memory channel.
@MainActor enum PrintExchange {
    static func run(_ job: PrintJob, channel: PrintChannel, progress: (String) -> Void) async throws {
        guard job.chunks.count >= 2 else { throw PrintFailure("Empty print job") }
        channel.discardReplies()
        try await channel.send(Data([0x10, 0xff, 0x40]))
        let state = try await channel.response(seconds: 4) { !$0.isEmpty }
        try NativeCore.ready(state[0])
        channel.discardReplies()
        try await channel.send(job.chunks[0])
        _ = try await channel.response(seconds: 4) { $0.range(of: Data("OK".utf8)) != nil }
        for index in 1..<job.chunks.count {
            try Task.checkCancellation()
            if index == job.chunks.count - 1 { channel.discardReplies() }
            progress("Sending \(index * 100 / job.chunks.count)%…")
            try await channel.send(job.chunks[index])
        }
        progress("Waiting for the printer to finish…")
        _ = try await channel.response(seconds: 90) { $0.range(of: Data("OK".utf8)) != nil }
    }
}
