import XCTest
@testable import SpotifyLite

final class SpotifyModelsTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    func testTrackPagingCursorUsesRawItemsAndStopsAtTheLastPage() {
        var cursor = TrackPagingCursor()

        cursor.advance(rawItemCount: 100, total: 162, next: "next-page")
        XCTAssertEqual(cursor.offset, 100)
        XCTAssertEqual(cursor.total, 162)
        XCTAssertTrue(cursor.hasMore)

        // The raw page may contain a null/unplayable track; its entry still
        // advances Spotify's offset and must not cause the page to repeat.
        cursor.advance(rawItemCount: 62, total: 162, next: nil)
        XCTAssertEqual(cursor.offset, 162)
        XCTAssertFalse(cursor.hasMore)
    }

    func testTrackPagingCursorResetAllowsOneInitialRequest() {
        var cursor = TrackPagingCursor()
        cursor.advance(rawItemCount: 1, total: 1, next: nil)

        cursor.reset()

        XCTAssertEqual(cursor.offset, 0)
        XCTAssertEqual(cursor.total, 0)
        XCTAssertTrue(cursor.hasMore)
    }

    func testPlaybackPollingSlowsDownWhileIdle() {
        XCTAssertEqual(PlaybackPollingPolicy.intervalSeconds(isPlaying: true), 5)
        XCTAssertEqual(PlaybackPollingPolicy.intervalSeconds(isPlaying: false), 30)
    }

    func testTrackPagingCursorStopsOnAnEmptyPage() {
        var cursor = TrackPagingCursor()

        cursor.advance(rawItemCount: 0, total: 10, next: "inconsistent-next-page")

        XCTAssertEqual(cursor.offset, 0)
        XCTAssertFalse(cursor.hasMore)
    }

    func testTrackDecodesSpotifyPayloadAndFormatsPresentationValues() throws {
        let json = #"""
        {
          "id": "track-1",
          "name": "Test Track",
          "uri": "spotify:track:track-1",
          "duration_ms": 185000,
          "artists": [
            { "id": "artist-1", "name": "First Artist" },
            { "id": "artist-2", "name": "Second Artist" }
          ],
          "album": {
            "id": "album-1",
            "name": "Test Album",
            "images": [
              { "url": "https://example.com/large.jpg", "width": 640, "height": 640 },
              { "url": "https://example.com/small.jpg", "width": 64, "height": 64 }
            ]
          }
        }
        """#

        let track = try decoder.decode(Track.self, from: Data(json.utf8))

        XCTAssertEqual(track.id, "track-1")
        XCTAssertEqual(track.artistNames, "First Artist, Second Artist")
        XCTAssertEqual(track.durationFormatted, "3:05")
        XCTAssertEqual(track.artworkURL?.absoluteString, "https://example.com/small.jpg")
        XCTAssertEqual(track.highResolutionArtworkURL?.absoluteString, "https://example.com/large.jpg")
    }

    func testPlaylistDetailUsesItemWrapperRequiredByCurrentAPI() throws {
        let json = #"""
        {
          "items": {
            "items": [
              {
                "item": {
                  "id": "track-1",
                  "name": "Wrapped Track",
                  "uri": "spotify:track:track-1",
                  "duration_ms": 1000,
                  "artists": [{ "id": "artist-1", "name": "Artist" }],
                  "album": null
                }
              },
              { "item": null }
            ],
            "next": "https://api.spotify.com/v1/playlists/playlist-1/items?offset=2&limit=2",
            "total": 343
          }
        }
        """#

        let response = try decoder.decode(PlaylistDetailResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.items.total, 343)
        XCTAssertEqual(
            response.items.next,
            "https://api.spotify.com/v1/playlists/playlist-1/items?offset=2&limit=2"
        )
        XCTAssertEqual(response.items.items.compactMap(\.item).map(\.name), ["Wrapped Track"])
    }

    func testPlaybackAndQueueResponsesDecodeSnakeCase() throws {
        let playbackJSON = #"""
        {
          "device": {
            "id": "device-1",
            "name": "Mac",
            "type": "Computer",
            "is_active": true,
            "volume_percent": 82
          },
          "is_playing": true,
          "progress_ms": 900,
          "item": null
        }
        """#
        let queueJSON = #"""
        { "currently_playing": null, "queue": [] }
        """#

        let playback = try decoder.decode(PlaybackState.self, from: Data(playbackJSON.utf8))
        let queue = try decoder.decode(QueueResponse.self, from: Data(queueJSON.utf8))

        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(playback.device?.volumePercent, 82)
        XCTAssertEqual(playback.progressMs, 900)
        XCTAssertTrue(queue.queue.isEmpty)
    }

    func testTokenResponseUsesOAuthCodingKeys() throws {
        let json = #"""
        { "access_token": "access", "refresh_token": "refresh", "expires_in": 3600 }
        """#

        let response = try JSONDecoder().decode(TokenResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.accessToken, "access")
        XCTAssertEqual(response.refreshToken, "refresh")
        XCTAssertEqual(response.expiresIn, 3600)
    }

    func testScopesContainPlaybackAndLibraryPermissions() {
        let scopes = Set(SpotifyAuthConfig.scopes.split(separator: " ").map(String.init))

        XCTAssertTrue(scopes.isSuperset(of: [
            "user-read-playback-state",
            "user-modify-playback-state",
            "playlist-read-private",
            "user-library-read"
        ]))
    }

    func testProgressInterpolatesOnlyWhilePlaying() {
        var state = PlaybackProgressState()
        let start = Date(timeIntervalSince1970: 1_000)

        state.applyRemoteState(
            trackID: "track-1",
            durationMs: 200_000,
            progressMs: 10_000,
            isPlaying: true,
            receivedAt: start
        )

        XCTAssertEqual(state.progress(at: start.addingTimeInterval(1.5)), 11_500)

        state.applyRemoteState(
            trackID: "track-1",
            durationMs: 200_000,
            progressMs: 25_000,
            isPlaying: false,
            receivedAt: start.addingTimeInterval(2)
        )

        XCTAssertEqual(state.progress(at: start.addingTimeInterval(8)), 25_000)
    }

    func testProgressIsClampedToDurationBounds() {
        var state = PlaybackProgressState()
        let start = Date(timeIntervalSince1970: 2_000)

        state.applyRemoteState(
            trackID: "track-1",
            durationMs: 3_000,
            progressMs: 2_900,
            isPlaying: true,
            receivedAt: start
        )

        XCTAssertEqual(state.progress(at: start.addingTimeInterval(3)), 3_000)
    }

    func testPendingSeekHoldsOptimisticValueUntilRemoteCatchesUp() {
        var state = PlaybackProgressState()
        let start = Date(timeIntervalSince1970: 3_000)

        state.applyRemoteState(
            trackID: "track-1",
            durationMs: 180_000,
            progressMs: 20_000,
            isPlaying: true,
            receivedAt: start
        )
        state.applyLocalSeek(
            trackID: "track-1",
            durationMs: 180_000,
            targetMs: 90_000,
            isPlaying: true,
            at: start.addingTimeInterval(0.1)
        )

        state.applyRemoteState(
            trackID: "track-1",
            durationMs: 180_000,
            progressMs: 21_000,
            isPlaying: true,
            receivedAt: start.addingTimeInterval(0.8)
        )

        XCTAssertEqual(state.progress(at: start.addingTimeInterval(1.1)), 91_000)
    }

    func testPendingSeekIsReconciledWhenRemotePositionMatches() {
        var state = PlaybackProgressState()
        let start = Date(timeIntervalSince1970: 4_000)

        state.applyRemoteState(
            trackID: "track-1",
            durationMs: 180_000,
            progressMs: 20_000,
            isPlaying: true,
            receivedAt: start
        )
        state.applyLocalSeek(
            trackID: "track-1",
            durationMs: 180_000,
            targetMs: 90_000,
            isPlaying: true,
            at: start.addingTimeInterval(0.1)
        )

        state.applyRemoteState(
            trackID: "track-1",
            durationMs: 180_000,
            progressMs: 90_400,
            isPlaying: true,
            receivedAt: start.addingTimeInterval(1)
        )

        XCTAssertNil(state.pendingSeek)
        XCTAssertEqual(state.progress(at: start.addingTimeInterval(1.2)), 90_600)
    }

    func testTrackChangeClearsPendingSeekAndUsesNewRemoteProgress() {
        var state = PlaybackProgressState()
        let start = Date(timeIntervalSince1970: 5_000)

        state.applyRemoteState(
            trackID: "track-1",
            durationMs: 180_000,
            progressMs: 20_000,
            isPlaying: true,
            receivedAt: start
        )
        state.applyLocalSeek(
            trackID: "track-1",
            durationMs: 180_000,
            targetMs: 90_000,
            isPlaying: true,
            at: start.addingTimeInterval(0.1)
        )

        state.applyRemoteState(
            trackID: "track-2",
            durationMs: 120_000,
            progressMs: 1_000,
            isPlaying: true,
            receivedAt: start.addingTimeInterval(0.5)
        )

        XCTAssertEqual(state.trackID, "track-2")
        XCTAssertNil(state.pendingSeek)
        XCTAssertEqual(state.progress(at: start.addingTimeInterval(0.6)), 1_100)
    }

    func testCancelPendingSeekClearsOptimisticStateForImmediateReconciliation() {
        var state = PlaybackProgressState()
        let start = Date(timeIntervalSince1970: 6_000)

        state.applyRemoteState(
            trackID: "track-1",
            durationMs: 180_000,
            progressMs: 20_000,
            isPlaying: true,
            receivedAt: start
        )
        state.applyLocalSeek(
            trackID: "track-1",
            durationMs: 180_000,
            targetMs: 90_000,
            isPlaying: true,
            at: start.addingTimeInterval(0.1)
        )
        state.cancelPendingSeek()

        state.applyRemoteState(
            trackID: "track-1",
            durationMs: 180_000,
            progressMs: 21_000,
            isPlaying: true,
            receivedAt: start.addingTimeInterval(0.2)
        )

        XCTAssertNil(state.pendingSeek)
        XCTAssertEqual(state.progress(at: start.addingTimeInterval(0.2)), 21_000)
    }

    func testCancelPendingSeekIsNoOpWhenNoPendingSeekExists() {
        var state = PlaybackProgressState()
        let start = Date(timeIntervalSince1970: 7_000)

        state.applyRemoteState(
            trackID: "track-1",
            durationMs: 120_000,
            progressMs: 30_000,
            isPlaying: false,
            receivedAt: start
        )
        state.cancelPendingSeek()

        XCTAssertNil(state.pendingSeek)
        XCTAssertEqual(state.progress(at: start.addingTimeInterval(5)), 30_000)
    }

    func testPendingSeekReconcilesWhenRemoteMatchesInterpolatedProgress() {
        var state = PlaybackProgressState()
        let start = Date(timeIntervalSince1970: 8_000)

        state.applyRemoteState(
            trackID: "track-1",
            durationMs: 180_000,
            progressMs: 20_000,
            isPlaying: true,
            receivedAt: start
        )
        state.applyLocalSeek(
            trackID: "track-1",
            durationMs: 180_000,
            targetMs: 90_000,
            isPlaying: true,
            at: start
        )

        state.applyRemoteState(
            trackID: "track-1",
            durationMs: 180_000,
            progressMs: 92_000,
            isPlaying: true,
            receivedAt: start.addingTimeInterval(2)
        )

        XCTAssertNil(state.pendingSeek)
        XCTAssertEqual(state.progress(at: start.addingTimeInterval(2.25)), 92_250)
    }

    func testPendingSeekExpiresAfterTimeoutEvenIfRemoteIsStale() {
        var state = PlaybackProgressState()
        let start = Date(timeIntervalSince1970: 9_000)

        state.applyRemoteState(
            trackID: "track-1",
            durationMs: 180_000,
            progressMs: 20_000,
            isPlaying: true,
            receivedAt: start
        )
        state.applyLocalSeek(
            trackID: "track-1",
            durationMs: 180_000,
            targetMs: 90_000,
            isPlaying: true,
            at: start.addingTimeInterval(0.1)
        )

        state.applyRemoteState(
            trackID: "track-1",
            durationMs: 180_000,
            progressMs: 21_000,
            isPlaying: true,
            receivedAt: start.addingTimeInterval(3.2)
        )

        XCTAssertNil(state.pendingSeek)
        XCTAssertEqual(state.progress(at: start.addingTimeInterval(3.2)), 21_000)
    }

    func testPlaybackStatusFreezeStopsInterpolationUntilResume() {
        var state = PlaybackProgressState()
        let start = Date(timeIntervalSince1970: 10_000)

        state.applyRemoteState(
            trackID: "track-1",
            durationMs: 180_000,
            progressMs: 10_000,
            isPlaying: true,
            receivedAt: start
        )
        state.applyPlaybackStatus(isPlaying: false, at: start.addingTimeInterval(1))

        XCTAssertEqual(state.progress(at: start.addingTimeInterval(5)), 11_000)

        state.applyPlaybackStatus(isPlaying: true, at: start.addingTimeInterval(5))

        XCTAssertEqual(state.progress(at: start.addingTimeInterval(6.5)), 12_500)
    }
}
