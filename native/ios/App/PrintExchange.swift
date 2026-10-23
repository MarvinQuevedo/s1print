import Foundation

@MainActor protocol PrintChannel {
    func discardReplies()
    func send(_ data: Data) async throws
    func response(seconds: Double, predicate: @escaping (Data) -> Bool) async throws -> Data
    /// Wait until the printer has accounted for everything already sent (windowed transports).
    func settleInFlight() async throws
}

extension PrintChannel {
    func settleInFlight() async throws {}
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
        // The printer answers `OK` once it has printed a raster command; with one command per page
        // that reply can arrive before the stop is even sent, and the stop then gets no reply of its
        // own. So replies are cleared before the last raster (dropping earlier blocks' `OK`s), and
        // anything from there on completes the job.
        let rasterHeader = Data([0x1D, 0x76, 0x30, 0x00])
        let lastRaster = job.chunks.lastIndex { $0.starts(with: rasterHeader) }
        let clearAt = lastRaster.map { max(1, $0) } ?? job.chunks.count - 1
        for index in 1..<job.chunks.count {
            try Task.checkCancellation()
            if index == clearAt {
                // Late per-packet notifications must not be mistaken for the completion reply.
                try await channel.settleInFlight()
                channel.discardReplies()
            }
            progress("Sending \(index * 100 / job.chunks.count)%…")
            try await channel.send(job.chunks[index])
        }
        progress("Waiting for the printer to finish…")
        _ = try await channel.response(seconds: BLESendTuning.completionSeconds, predicate: isCompletion)
    }

    /// FF01 error replies the vendor SDK aborts on (`FF 01` out of paper, `FF 02` cover open,
    /// `FF 03`/`FF 13` overheated, `FF 04` low battery); nil for anything else.
    nonisolated static func printerError(_ data: Data) -> String? {
        guard data.count == 2, data[data.startIndex] == 0xFF else { return nil }
        switch data[data.startIndex + 1] {
        case 0x01: return "The printer is out of paper. Load a roll and print again."
        case 0x02: return "The printer cover is open. Close it and print again."
        case 0x03, 0x13: return "The printer is too hot. Let it cool down, then print again."
        case 0x04: return "The printer battery is low. Charge it, then print again."
        default: return nil
        }
    }

    /// The stop command answers `OK`, or a lone `0xAA` byte on some firmware; either characteristic.
    static func isCompletion(_ data: Data) -> Bool {
        data.range(of: Data("OK".utf8)) != nil || data == Data([0xAA])
    }
}
