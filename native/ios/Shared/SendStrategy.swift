import Foundation

/// How raster data is paced onto the BLE link. Stored in the App Group so the app and the share
/// extension agree; the picker lives in the main app (diagnostics).
enum SendStrategy: String, CaseIterable, Identifiable, Codable {
    /// Acknowledged writes plus a fixed pause after each packet (the original behaviour).
    case ackedPaced
    /// Acknowledged writes, no pause.
    case acked
    /// Writes without response, bounded by the printer's own notifications.
    case windowed
    /// Writes without response gated only by Core Bluetooth's readiness callback.
    case flow

    static let defaultStrategy: SendStrategy = .windowed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ackedPaced: "Acknowledged, 10 ms pause"
        case .acked: "Acknowledged"
        case .windowed: "Windowed (recommended)"
        case .flow: "Unacknowledged, flow control"
        }
    }
}

/// Every transport timing in one place so device results can tune them.
enum BLESendTuning {
    /// Packets that may be sent beyond the last printer notification (`windowed`).
    static let window = 4
    /// Window full and no notification for this long: the printer may not notify at all.
    static let silenceTimeout: TimeInterval = 2
    /// Packet spacing while falling back after that silence.
    static let fallbackInterval: TimeInterval = 0.05
    /// Fixed pause of `ackedPaced`.
    static let ackedPause: TimeInterval = 0.01
    static let maximumPacket = 512
    /// Final confirmation ceiling.
    static let completionSeconds: Double = 90
}

/// Notification-gated send window, pure so it can be tested without Core Bluetooth.
/// Time is passed in (seconds on any monotonic clock); nothing here sleeps or touches hardware.
struct SendWindow: Equatable {
    enum Decision: Equatable {
        /// Send now (or, for `drain`, nothing is left to wait for).
        case go
        /// Not yet; wake after `timeout` seconds, or `nil` to wait for an external event only.
        case wait(timeout: TimeInterval?)
    }

    let window: Int
    let silenceTimeout: TimeInterval
    let fallbackInterval: TimeInterval
    /// Packets sent that no notification has accounted for yet.
    private(set) var inFlight = 0
    private(set) var lastNotification: TimeInterval?
    private(set) var lastSend: TimeInterval?
    private var fullSince: TimeInterval?

    init(window: Int = BLESendTuning.window, silenceTimeout: TimeInterval = BLESendTuning.silenceTimeout,
         fallbackInterval: TimeInterval = BLESendTuning.fallbackInterval) {
        self.window = max(1, window)
        self.silenceTimeout = silenceTimeout
        self.fallbackInterval = fallbackInterval
    }

    /// May a packet go out now? `canSend` is Core Bluetooth's `canSendWriteWithoutResponse`.
    mutating func next(at now: TimeInterval, canSend: Bool) -> Decision {
        if inFlight >= window {
            if fullSince == nil { fullSince = now }
            let silent = now - max(lastNotification ?? -.infinity, fullSince ?? now)
            if silent < silenceTimeout { return .wait(timeout: silenceTimeout - silent) }
            // Silence: one packet per fallback interval until a notification arrives.
            if let lastSend, now - lastSend < fallbackInterval {
                return .wait(timeout: fallbackInterval - (now - lastSend))
            }
        }
        return canSend ? .go : .wait(timeout: nil)
    }

    mutating func noteSent(at now: TimeInterval) {
        inFlight += 1
        lastSend = now
    }

    /// Any notification frees one slot. After a fallback pile-up (more than `window` unaccounted
    /// packets) it clamps to one free slot, so the normal window resumes instead of waiting for
    /// the whole backlog to be acknowledged.
    mutating func noteNotification(at now: TimeInterval) {
        lastNotification = now
        fullSince = nil
        inFlight = inFlight > window ? window - 1 : max(0, inFlight - 1)
    }

    /// Wait until the printer has accounted for everything sent, or has been silent for `silenceTimeout`.
    func drain(at now: TimeInterval) -> Decision {
        guard inFlight > 0 else { return .go }
        let silent = now - max(lastNotification ?? -.infinity, lastSend ?? -.infinity)
        return silent >= silenceTimeout ? .go : .wait(timeout: silenceTimeout - silent)
    }
}
