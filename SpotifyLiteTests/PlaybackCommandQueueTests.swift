import XCTest
@testable import SpotifyLite

final class PlaybackCommandQueueTests: XCTestCase {
    func testRapidIdenticalCommandsCoalesceIntoOnePendingSlot() {
        var queue = PlaybackCommandQueue()

        XCTAssertEqual(queue.enqueue(.next), .enqueued)
        XCTAssertEqual(queue.enqueue(.next), .coalesced)
        XCTAssertEqual(queue.enqueue(.next), .coalesced)
        XCTAssertEqual(queue.pending, [.next])
    }

    func testDifferentCommandsDoNotCoalesce() {
        var queue = PlaybackCommandQueue()

        XCTAssertEqual(queue.enqueue(.next), .enqueued)
        XCTAssertEqual(queue.enqueue(.pause), .enqueued)
        XCTAssertEqual(queue.enqueue(.next), .enqueued)
        XCTAssertEqual(queue.pending, [.next, .pause, .next])
    }

    func testInFlightNextDoesNotSwallowALaterNext() {
        var queue = PlaybackCommandQueue()
        _ = queue.enqueue(.next)
        XCTAssertEqual(queue.startNext(), .next)
        XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertEqual(queue.inFlight, .next)

        XCTAssertEqual(queue.enqueue(.next), .enqueued)
        XCTAssertEqual(queue.enqueue(.next), .coalesced)
        XCTAssertEqual(queue.pending, [.next])

        queue.finishInFlight()
        XCTAssertEqual(queue.startNext(), .next)
        XCTAssertNil(queue.startNext())
    }

    func testVolumeAndSeekCoalesceOnlyWhenIdentical() {
        var queue = PlaybackCommandQueue()

        XCTAssertEqual(queue.enqueue(.volume(percent: 40)), .enqueued)
        XCTAssertEqual(queue.enqueue(.volume(percent: 40)), .coalesced)
        XCTAssertEqual(queue.enqueue(.volume(percent: 55)), .enqueued)
        XCTAssertEqual(
            queue.enqueue(.seek(positionMs: 1_000, expectedTrackID: "track")),
            .enqueued
        )
        XCTAssertEqual(
            queue.enqueue(.seek(positionMs: 1_000, expectedTrackID: "track")),
            .coalesced
        )
        XCTAssertEqual(
            queue.enqueue(.seek(positionMs: 2_000, expectedTrackID: "track")),
            .enqueued
        )
        XCTAssertEqual(queue.pending, [
            .volume(percent: 40),
            .volume(percent: 55),
            .seek(positionMs: 1_000, expectedTrackID: "track"),
            .seek(positionMs: 2_000, expectedTrackID: "track")
        ])
    }

    func testStalePollIsHeldUntilTheExistingPollDeadline() {
        let mutation = PlaybackMutation.setPlaying(true)
        let stale = PlaybackQueueSnapshot(isPlaying: false)
        let confirmed = PlaybackQueueSnapshot(isPlaying: true)
        let now = Date(timeIntervalSince1970: 1_000)
        let deadline = PlaybackPollConfirmation.deadline(now: now, pollIntervalSeconds: 5)

        XCTAssertFalse(
            PlaybackPollConfirmation.shouldApplyRemote(
                stale, after: mutation, now: now, deadline: deadline
            )
        )
        XCTAssertTrue(
            PlaybackPollConfirmation.shouldApplyRemote(
                confirmed, after: mutation, now: now, deadline: deadline
            )
        )
        XCTAssertTrue(
            PlaybackPollConfirmation.shouldApplyRemote(
                stale, after: mutation, now: deadline, deadline: deadline
            )
        )
    }

    func testSetPlayingTreatsAMissingPlayerPayloadAsNotPlaying() {
        XCTAssertTrue(
            PlaybackQueueSync.isStale(PlaybackQueueSnapshot(), after: .setPlaying(true))
        )
        XCTAssertFalse(
            PlaybackQueueSync.isStale(
                PlaybackQueueSnapshot(isPlaying: true),
                after: .setPlaying(true)
            )
        )
    }

    func testSetVolumeIsStaleUntilTheDeviceReportsTheSamePercent() {
        let mutation = PlaybackMutation.setVolume(percent: 80)
        XCTAssertTrue(
            PlaybackQueueSync.isStale(
                PlaybackQueueSnapshot(volumePercent: 20),
                after: mutation
            )
        )
        XCTAssertFalse(
            PlaybackQueueSync.isStale(
                PlaybackQueueSnapshot(volumePercent: 80),
                after: mutation
            )
        )
        XCTAssertFalse(PlaybackQueueSync.isStale(PlaybackQueueSnapshot(), after: mutation))
    }
}
