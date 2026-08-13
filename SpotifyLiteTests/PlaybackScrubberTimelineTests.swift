import XCTest
@testable import SpotifyLite

final class PlaybackScrubberTimelineTests: XCTestCase {
    func testTimelinePausesWhenNothingIsPlaying() {
        XCTAssertTrue(PlaybackScrubberTimeline.isPaused(
            isPlaying: false, durationMs: 180_000, isScrubbing: false))
    }

    func testTimelinePausesWhenThereIsNoTrack() {
        XCTAssertTrue(PlaybackScrubberTimeline.isPaused(
            isPlaying: true, durationMs: 0, isScrubbing: false))
    }

    func testTimelinePausesWhileScrubbingSoDragUsesLocalState() {
        XCTAssertTrue(PlaybackScrubberTimeline.isPaused(
            isPlaying: true, durationMs: 180_000, isScrubbing: true))
    }

    func testTimelineTicksOnlyWhilePlayingATrack() {
        XCTAssertFalse(PlaybackScrubberTimeline.isPaused(
            isPlaying: true, durationMs: 180_000, isScrubbing: false))
    }

    func testTickIntervalIsHalfSecond() {
        XCTAssertEqual(PlaybackScrubberTimeline.tickSeconds, 0.5)
    }
}
