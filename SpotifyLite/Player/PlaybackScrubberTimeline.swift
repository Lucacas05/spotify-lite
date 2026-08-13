import Foundation

/// Pause/tick policy for the player-bar seek timeline.
///
/// A periodic `TimelineView` that keeps firing while paused was measured at
/// ~15% CPU idle (full `NSHostingView.layout()` 5×/s). The schedule must only
/// tick while a track is actually playing; scrubbing uses local `@State`.
enum PlaybackScrubberTimeline {
    /// Time labels only change once per second; 0.5s is enough for the bar
    /// because `PlaybackProgressState.progress(at:)` interpolates.
    static let tickSeconds: TimeInterval = 0.5

    static func isPaused(isPlaying: Bool, durationMs: Int, isScrubbing: Bool) -> Bool {
        !isPlaying || durationMs <= 0 || isScrubbing
    }
}
