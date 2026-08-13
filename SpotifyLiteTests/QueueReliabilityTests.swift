import XCTest
@testable import SpotifyLite

final class QueueReliabilityTests: XCTestCase {
    func testFailedRefreshPreservesLastSuccessfulSnapshot() {
        var state = QueueRefreshState()
        let first = track("one")
        let second = track("two")

        let loaded = state.beginRefresh(force: false)!
        state.applySuccess(
            generation: loaded,
            response: QueueResponse(currentlyPlaying: first, queue: [second])
        )

        let failed = state.beginRefresh(force: false)!
        state.applyFailure(generation: failed, message: "No connection to Spotify.")

        XCTAssertEqual(state.upcoming.map(\.uri), [second.uri])
        XCTAssertEqual(state.currentlyPlaying?.uri, first.uri)
        XCTAssertEqual(state.lastError, "No connection to Spotify.")
        XCTAssertTrue(state.hasLoadedSuccessfully)
        XCTAssertTrue(state.presentation.showsRows)
        XCTAssertTrue(state.presentation.showsInlineError)
        XCTAssertFalse(state.presentation.showsEmptyState)
        XCTAssertFalse(state.presentation.showsInitialSpinner)
    }

    func testSupersededResponseCannotOverwriteNewerGeneration() {
        var state = QueueRefreshState()
        let stale = track("stale")
        let fresh = track("fresh")

        let first = state.beginRefresh(force: false)!
        let second = state.beginRefresh(force: true)!
        XCTAssertNotEqual(first, second)

        state.applySuccess(
            generation: first,
            response: QueueResponse(currentlyPlaying: nil, queue: [stale])
        )
        XCTAssertTrue(state.upcoming.isEmpty)
        XCTAssertTrue(state.isLoading)

        state.applySuccess(
            generation: second,
            response: QueueResponse(currentlyPlaying: nil, queue: [fresh])
        )
        XCTAssertEqual(state.upcoming.map(\.id), ["fresh"])
        XCTAssertFalse(state.isLoading)
    }

    func testRepeatedRefreshIntentsCoalesceIntoOneInFlightRequest() {
        var state = QueueRefreshState()

        let first = state.beginRefresh(force: false)
        let coalesced = state.beginRefresh(force: false)

        XCTAssertEqual(first, 1)
        XCTAssertNil(coalesced)
        XCTAssertEqual(state.generation, 1)
        XCTAssertTrue(state.isLoading)
    }

    func testForcedRefreshStartsANewerGenerationWhileOneIsInFlight() {
        var state = QueueRefreshState()

        XCTAssertEqual(state.beginRefresh(force: false), 1)
        XCTAssertEqual(state.beginRefresh(force: true), 2)
        XCTAssertEqual(state.generation, 2)
    }

    func testDuplicateTracksRetainDistinctStableRowIdentities() {
        let duplicate = track("same")
        let other = track("other")
        let rows = QueueRowItem.rows(from: [duplicate, other, duplicate])

        XCTAssertEqual(rows.map(\.id), ["same#0", "other#0", "same#1"])
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
        XCTAssertEqual(rows[0].occurrence, 0)
        XCTAssertEqual(rows[2].occurrence, 1)
        XCTAssertEqual(rows[0].id, QueueRowItem.rows(from: [duplicate, other, duplicate])[0].id)
    }

    func testEmptyStateRequiresASuccessfulEmptyResponse() {
        var state = QueueRefreshState()
        XCTAssertFalse(state.presentation.showsEmptyState)
        XCTAssertFalse(state.presentation.showsFailedEmpty)

        let generation = state.beginRefresh(force: false)!
        XCTAssertTrue(state.presentation.showsInitialSpinner)

        state.applyFailure(generation: generation, message: "Spotify responded 500")
        XCTAssertTrue(state.presentation.showsFailedEmpty)
        XCTAssertFalse(state.presentation.showsEmptyState)

        let retry = state.beginRefresh(force: false)!
        state.applySuccess(generation: retry, response: QueueResponse(currentlyPlaying: nil, queue: []))
        XCTAssertTrue(state.presentation.showsEmptyState)
        XCTAssertFalse(state.presentation.showsFailedEmpty)
        XCTAssertFalse(state.presentation.showsInlineError)
    }

    func testPlayAndPlayNextSchedulePlaybackAndQueueSynchronization() {
        let play = PlaybackMutation.play(expectedURI: "spotify:track:one")
        let playNext = PlaybackMutation.addToQueue(
            uri: "spotify:track:two",
            previousMatchingCount: 0
        )

        XCTAssertTrue(play.requiresPlaybackAndQueueSync)
        XCTAssertTrue(playNext.requiresPlaybackAndQueueSync)
        XCTAssertTrue(PlaybackMutation.skipForward(previousURI: "a", expectedNextURI: "b")
            .requiresPlaybackAndQueueSync)
        XCTAssertTrue(PlaybackMutation.shuffle(enabled: true).requiresPlaybackAndQueueSync)
        XCTAssertTrue(PlaybackMutation.transfer(deviceID: "device-1").requiresPlaybackAndQueueSync)
    }

    func testSyncRetriesOnlyWhenTheSnapshotIsStale() {
        let play = PlaybackMutation.play(expectedURI: "spotify:track:one")
        XCTAssertTrue(PlaybackQueueSync.isStale(
            PlaybackQueueSnapshot(playingURI: "spotify:track:old"),
            after: play
        ))
        XCTAssertFalse(PlaybackQueueSync.isStale(
            PlaybackQueueSnapshot(playingURI: "spotify:track:one"),
            after: play
        ))
        XCTAssertFalse(PlaybackQueueSync.isStale(
            PlaybackQueueSnapshot(),
            after: .play(expectedURI: nil)
        ))

        let add = PlaybackMutation.addToQueue(uri: "spotify:track:two", previousMatchingCount: 1)
        XCTAssertTrue(PlaybackQueueSync.isStale(
            PlaybackQueueSnapshot(upcomingURIs: ["spotify:track:two"]),
            after: add
        ))
        XCTAssertFalse(PlaybackQueueSync.isStale(
            PlaybackQueueSnapshot(upcomingURIs: ["spotify:track:two", "spotify:track:two"]),
            after: add
        ))

        XCTAssertEqual(PlaybackQueueSync.maxAttempts, 3)
    }

    func testSkipIsStaleUntilCurrentlyPlayingChanges() {
        let skip = PlaybackMutation.skipForward(
            previousURI: "spotify:track:one",
            expectedNextURI: "spotify:track:two"
        )
        XCTAssertTrue(PlaybackQueueSync.isStale(
            PlaybackQueueSnapshot(playingURI: "spotify:track:one"),
            after: skip
        ))
        XCTAssertFalse(PlaybackQueueSync.isStale(
            PlaybackQueueSnapshot(playingURI: "spotify:track:two"),
            after: skip
        ))
    }

    func testQueueRowActivationCannotStartIsolatedPlayback() {
        XCTAssertFalse(TrackRowBehavior.queue.activatesPlayback)
        XCTAssertFalse(TrackRowBehavior.queue.showsPlayNextAction)
        XCTAssertNil(TrackRowBehavior.queue.playNextAccessibilityLabel)
        XCTAssertTrue(TrackRowBehavior.catalog.activatesPlayback)
        XCTAssertEqual(TrackRowBehavior.catalog.playNextAccessibilityLabel, "Play next")
    }

    func testRefreshButtonIsDisabledWhileARequestIsInFlight() {
        var state = QueueRefreshState()
        XCTAssertTrue(state.presentation.refreshEnabled)
        _ = state.beginRefresh(force: false)
        XCTAssertFalse(state.presentation.refreshEnabled)
    }

    private func track(_ id: String) -> Track {
        Track(
            id: id,
            name: id,
            uri: "spotify:track:\(id)",
            durationMs: 180_000,
            artists: [Artist(id: "artist", name: "Artist")],
            album: nil
        )
    }
}
