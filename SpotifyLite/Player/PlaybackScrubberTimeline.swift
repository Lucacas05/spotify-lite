import Foundation

/// Seek-bar timeline policy.
///
/// A `TimelineView` that remains in the SwiftUI graph while paused still
/// drives `NSHostingView.layout()` even with `paused: true`. The timed path
/// must exist only while a track is playing and the user is not dragging.
enum PlaybackScrubberPath: Equatable {
    case `static`
    case timed
}

enum PlaybackScrubberTimeline {
    /// Time labels only change once per second; 0.5s is enough for the bar
    /// because `PlaybackProgressState.progress(at:)` interpolates.
    static let tickSeconds: TimeInterval = 0.5

    static func usesTimedScrubber(isPlaying: Bool, durationMs: Int, isScrubbing: Bool) -> Bool {
        isPlaying && durationMs > 0 && !isScrubbing
    }

    static func path(isPlaying: Bool, durationMs: Int, isScrubbing: Bool) -> PlaybackScrubberPath {
        usesTimedScrubber(isPlaying: isPlaying, durationMs: durationMs, isScrubbing: isScrubbing)
            ? .timed
            : .static
    }
}
