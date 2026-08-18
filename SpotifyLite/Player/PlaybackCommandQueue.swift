import Foundation

/// One global serial queue for play/pause/next/previous/seek/volume/shuffle.
/// Identical pending commands coalesce (`next` + `next` → one `next`).
/// In-flight work is not coalesced, so a second `next` after the first HTTP
/// has started still skips another track.
struct PlaybackCommandQueue: Equatable {
    enum Command: Equatable {
        case play
        case pause
        case next
        case previous
        case seek(positionMs: Int, expectedTrackID: String?)
        case volume(percent: Int)
        case shuffle(enabled: Bool)
    }

    enum EnqueueResult: Equatable {
        case enqueued
        case coalesced
    }

    private(set) var pending: [Command] = []
    private(set) var inFlight: Command?

    mutating func enqueue(_ command: Command) -> EnqueueResult {
        if pending.last == command {
            return .coalesced
        }
        pending.append(command)
        return .enqueued
    }

    mutating func startNext() -> Command? {
        guard inFlight == nil, !pending.isEmpty else { return nil }
        let command = pending.removeFirst()
        inFlight = command
        return command
    }

    mutating func finishInFlight() {
        inFlight = nil
    }
}

/// After a transport command succeeds, wait for the existing 5s/30s poll.
/// Do not issue a fresh `GET /me/player` — that stacks on PERFORMANCE.md's cadence.
enum PlaybackPollConfirmation {
    /// Apply this poll when it confirms the mutation, or when the deadline
    /// misses. A miss still uses this payload; it must not start a new GET.
    static func shouldApplyRemote(
        _ snapshot: PlaybackQueueSnapshot,
        after mutation: PlaybackMutation,
        now: Date,
        deadline: Date
    ) -> Bool {
        if !PlaybackQueueSync.isStale(snapshot, after: mutation) {
            return true
        }
        return now >= deadline
    }

    static func deadline(now: Date, pollIntervalSeconds: Int) -> Date {
        now.addingTimeInterval(TimeInterval(max(pollIntervalSeconds, 0)))
    }
}
