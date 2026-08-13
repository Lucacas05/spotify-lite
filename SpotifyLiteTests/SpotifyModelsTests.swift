import XCTest
@testable import SpotifyLite

final class SpotifyModelsTests: XCTestCase {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

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
}
