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
        XCTAssertFalse(PlaybackMutation.skipForward(previousURI: "a", expectedNextURI: "b")
            .requiresPlaybackAndQueueSync)
        XCTAssertFalse(PlaybackMutation.shuffle(enabled: true).requiresPlaybackAndQueueSync)
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

    func testExistingPollAppliesWhenConfirmedOrWhenTheDeadlineMisses() {
        let mutation = PlaybackMutation.setPlaying(true)
        let stale = PlaybackQueueSnapshot(isPlaying: false)
        let confirmed = PlaybackQueueSnapshot(isPlaying: true)
        let now = Date(timeIntervalSince1970: 1_000)
        let deadline = PlaybackQueueSync.confirmationDeadline(now: now, pollIntervalSeconds: 5)

        XCTAssertFalse(
            PlaybackQueueSync.shouldApplyRemote(stale, after: mutation, now: now, deadline: deadline)
        )
        XCTAssertTrue(
            PlaybackQueueSync.shouldApplyRemote(confirmed, after: mutation, now: now, deadline: deadline)
        )
        XCTAssertTrue(
            PlaybackQueueSync.shouldApplyRemote(stale, after: mutation, now: deadline, deadline: deadline)
        )
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
        XCTAssertFalse(PlaybackQueueSync.isStale(
            PlaybackQueueSnapshot(playingURI: "spotify:track:shuffled"),
            after: skip
        ))
    }

    func testStaleSkipPollIsNotAppliedEvenAfterTheDeadline() {
        let skip = PlaybackMutation.skipForward(
            previousURI: "spotify:track:one",
            expectedNextURI: "spotify:track:two"
        )
        let stale = PlaybackQueueSnapshot(playingURI: "spotify:track:one")
        let caughtUp = PlaybackQueueSnapshot(playingURI: "spotify:track:two")
        let now = Date(timeIntervalSince1970: 1_000)
        let deadline = PlaybackQueueSync.confirmationDeadline(now: now, pollIntervalSeconds: 5)

        XCTAssertTrue(skip.ignoresStalePollAfterSuccess)
        XCTAssertTrue(PlaybackMutation.skipBack(previousURI: "spotify:track:one").ignoresStalePollAfterSuccess)
        XCTAssertFalse(
            PlaybackQueueSync.shouldApplyRemote(stale, after: skip, now: now, deadline: deadline)
        )
        XCTAssertFalse(
            PlaybackQueueSync.shouldApplyRemote(stale, after: skip, now: deadline, deadline: deadline)
        )
        XCTAssertTrue(
            PlaybackQueueSync.shouldApplyRemote(caughtUp, after: skip, now: now, deadline: deadline)
        )
    }

    func testOptimisticNextKeepsTheQueueAlignedWithThePlayerBar() {
        var state = QueueRefreshState()
        let current = track("one")
        let next = track("two")
        let later = track("three")
        let generation = state.beginRefresh(force: false)!
        state.applySuccess(
            generation: generation,
            response: QueueResponse(currentlyPlaying: current, queue: [next, later])
        )

        state.applyOptimisticSkipForward()

        XCTAssertEqual(state.currentlyPlaying?.uri, next.uri)
        XCTAssertEqual(state.upcoming.map(\.uri), [later.uri])
        XCTAssertEqual(state.generation, generation + 1)
        XCTAssertFalse(state.isLoading)

        state.applySuccess(
            generation: generation,
            response: QueueResponse(currentlyPlaying: current, queue: [next, later])
        )
        XCTAssertEqual(state.currentlyPlaying?.uri, next.uri)
        XCTAssertEqual(state.upcoming.map(\.uri), [later.uri])
    }

    func testQueueAlignsToThePlayerBarWithoutInventingOrder() {
        var state = QueueRefreshState()
        let current = track("one")
        let next = track("two")
        let later = track("three")
        let generation = state.beginRefresh(force: false)!
        state.applySuccess(
            generation: generation,
            response: QueueResponse(currentlyPlaying: current, queue: [next, later])
        )

        state.alignToPlayingURI(next.uri)
        XCTAssertEqual(state.currentlyPlaying?.uri, next.uri)
        XCTAssertEqual(state.upcoming.map(\.uri), [later.uri])

        state.alignToPlayingURI("spotify:track:shuffled")
        XCTAssertEqual(state.currentlyPlaying?.uri, next.uri)
        XCTAssertEqual(state.upcoming.map(\.uri), [later.uri])
    }

    func testOptimisticSkipDiscardsInFlightQueueFetch() {
        var state = QueueRefreshState()
        let current = track("one")
        let next = track("two")
        let loaded = state.beginRefresh(force: false)!
        state.applySuccess(
            generation: loaded,
            response: QueueResponse(currentlyPlaying: current, queue: [next])
        )
        let inFlight = state.beginRefresh(force: true)!
        XCTAssertTrue(state.isLoading)

        state.applyOptimisticSkipForward()
        state.applySuccess(
            generation: inFlight,
            response: QueueResponse(currentlyPlaying: current, queue: [next])
        )

        XCTAssertEqual(state.currentlyPlaying?.uri, next.uri)
        XCTAssertTrue(state.upcoming.isEmpty)
        XCTAssertFalse(state.isLoading)
    }

    func testStaleSkipPollIsIgnoredEvenWhenALaterPlayPauseIsPending() {
        let skip = PlaybackMutation.skipForward(
            previousURI: "spotify:track:one",
            expectedNextURI: "spotify:track:two"
        )
        let stale = PlaybackQueueSnapshot(playingURI: "spotify:track:one", isPlaying: false)
        let empty = PlaybackQueueSnapshot()
        let caughtUp = PlaybackQueueSnapshot(playingURI: "spotify:track:two", isPlaying: false)
        let now = Date(timeIntervalSince1970: 1_000)
        let deadline = PlaybackQueueSync.confirmationDeadline(now: now, pollIntervalSeconds: 5)

        XCTAssertEqual(skip.playingURIToIgnoreAfterSuccess, "spotify:track:one")
        XCTAssertFalse(
            PlaybackQueueSync.shouldApplyPlaybackPoll(
                stale,
                pendingMutation: .setPlaying(false),
                ignoringPlayingURI: skip.playingURIToIgnoreAfterSuccess,
                now: now,
                deadline: deadline
            )
        )
        XCTAssertFalse(
            PlaybackQueueSync.shouldApplyPlaybackPoll(
                empty,
                pendingMutation: .setPlaying(false),
                ignoringPlayingURI: skip.playingURIToIgnoreAfterSuccess,
                now: deadline,
                deadline: deadline
            )
        )
        XCTAssertTrue(
            PlaybackQueueSync.shouldApplyPlaybackPoll(
                caughtUp,
                pendingMutation: .setPlaying(false),
                ignoringPlayingURI: skip.playingURIToIgnoreAfterSuccess,
                now: now,
                deadline: deadline
            )
        )
    }

    func testPreviousConfirmsFromMutationHTTPAndIgnoresStalePolls() {
        let previous = PlaybackMutation.skipBack(previousURI: "spotify:track:two")
        XCTAssertFalse(previous.requiresPlaybackAndQueueSync)
        XCTAssertEqual(previous.playingURIToIgnoreAfterSuccess, "spotify:track:two")

        let stillOnCurrent = PlaybackQueueSnapshot(playingURI: "spotify:track:two")
        let caughtUp = PlaybackQueueSnapshot(playingURI: "spotify:track:one")
        let now = Date(timeIntervalSince1970: 1_000)
        let deadline = PlaybackQueueSync.confirmationDeadline(now: now, pollIntervalSeconds: 5)

        XCTAssertFalse(
            PlaybackQueueSync.shouldApplyPlaybackPoll(
                stillOnCurrent,
                pendingMutation: nil,
                ignoringPlayingURI: previous.playingURIToIgnoreAfterSuccess,
                now: deadline,
                deadline: deadline
            )
        )
        XCTAssertTrue(
            PlaybackQueueSync.shouldApplyPlaybackPoll(
                caughtUp,
                pendingMutation: nil,
                ignoringPlayingURI: previous.playingURIToIgnoreAfterSuccess,
                now: now,
                deadline: nil
            )
        )
        XCTAssertTrue(
            PlaybackQueueSync.shouldApplyPlaybackPoll(
                caughtUp,
                pendingMutation: .skipForward(
                    previousURI: "spotify:track:one",
                    expectedNextURI: "spotify:track:two"
                ),
                ignoringPlayingURI: previous.playingURIToIgnoreAfterSuccess,
                now: now,
                deadline: deadline
            )
        )
    }

    func testNewerTransportCommandsSupersedeInFlightPosts() {
        XCTAssertTrue(PlaybackCommand.previous.supersedes(.next))
        XCTAssertTrue(PlaybackCommand.next.supersedes(.previous))
        XCTAssertTrue(PlaybackCommand.pause.supersedes(.play))
        XCTAssertTrue(
            PlaybackCommand.seek(positionMs: 2_000, expectedTrackID: "a")
                .supersedes(.seek(positionMs: 1_000, expectedTrackID: "a"))
        )
        XCTAssertFalse(PlaybackCommand.next.supersedes(.next))
        XCTAssertFalse(PlaybackCommand.pause.supersedes(.next))
        XCTAssertFalse(PlaybackCommand.next.supersedes(.pause))
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
