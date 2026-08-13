import XCTest
@testable import SpotifyLite

final class PlaybackScrubberTimelineTests: XCTestCase {
    func testStaticPathIsSelectedWhenNothingIsPlaying() {
        XCTAssertEqual(
            PlaybackScrubberTimeline.path(isPlaying: false, durationMs: 180_000, isScrubbing: false),
            .static
        )
        XCTAssertFalse(PlaybackScrubberTimeline.usesTimedScrubber(
            isPlaying: false, durationMs: 180_000, isScrubbing: false))
    }

    func testStaticPathIsSelectedWhenPlaybackIsPaused() {
        XCTAssertEqual(
            PlaybackScrubberTimeline.path(isPlaying: false, durationMs: 180_000, isScrubbing: false),
            .static
        )
    }

    func testStaticPathIsSelectedWhenThereIsNoTrack() {
        XCTAssertEqual(
            PlaybackScrubberTimeline.path(isPlaying: true, durationMs: 0, isScrubbing: false),
            .static
        )
    }

    func testStaticPathIsSelectedWhileScrubbingSoDragUsesLocalState() {
        XCTAssertEqual(
            PlaybackScrubberTimeline.path(isPlaying: true, durationMs: 180_000, isScrubbing: true),
            .static
        )
    }

    func testTimedPathExistsOnlyWhilePlayingATrack() {
        XCTAssertEqual(
            PlaybackScrubberTimeline.path(isPlaying: true, durationMs: 180_000, isScrubbing: false),
            .timed
        )
        XCTAssertTrue(PlaybackScrubberTimeline.usesTimedScrubber(
            isPlaying: true, durationMs: 180_000, isScrubbing: false))
    }

    func testTickIntervalIsHalfSecond() {
        XCTAssertEqual(PlaybackScrubberTimeline.tickSeconds, 0.5)
    }
}
