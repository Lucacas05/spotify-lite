import Foundation

/// Commands that can change Spotify's reported queue or currently-playing item.
enum PlaybackMutation: Equatable {
    case play(expectedURI: String?)
    case skipForward(previousURI: String?, expectedNextURI: String?)
    case skipBack(previousURI: String?)
    case addToQueue(uri: String, previousMatchingCount: Int)
    case shuffle(enabled: Bool)
    case transfer(deviceID: String)

    var requiresPlaybackAndQueueSync: Bool { true }
}

/// Flattened playback + queue view used to decide whether Spotify has caught up.
struct PlaybackQueueSnapshot: Equatable {
    var playingURI: String?
    var shuffleState: Bool?
    var deviceID: String?
    var currentlyPlayingURI: String?
    var upcomingURIs: [String]

    init(
        playingURI: String? = nil,
        shuffleState: Bool? = nil,
        deviceID: String? = nil,
        currentlyPlayingURI: String? = nil,
        upcomingURIs: [String] = []
    ) {
        self.playingURI = playingURI
        self.shuffleState = shuffleState
        self.deviceID = deviceID
        self.currentlyPlayingURI = currentlyPlayingURI
        self.upcomingURIs = upcomingURIs
    }

    init(playback: PlaybackState?, currentlyPlaying: Track?, upcoming: [Track]) {
        self.init(
            playingURI: playback?.item?.uri,
            shuffleState: playback?.shuffleState,
            deviceID: playback?.device?.id,
            currentlyPlayingURI: currentlyPlaying?.uri,
            upcomingURIs: upcoming.map(\.uri)
        )
    }

    var reportedPlayingURI: String? {
        playingURI ?? currentlyPlayingURI
    }
}

/// Shared post-mutation coordinator: one playback refresh + one queue refresh,
/// with a short bounded retry only when the snapshot is demonstrably stale.
enum PlaybackQueueSync {
    static let maxAttempts = 3
    static var propagationDelay: Duration { .milliseconds(400) }
    static var retryDelay: Duration { .milliseconds(350) }

    static func isStale(_ snapshot: PlaybackQueueSnapshot, after mutation: PlaybackMutation) -> Bool {
        switch mutation {
        case .play(let expectedURI):
            guard let expectedURI else { return false }
            return snapshot.reportedPlayingURI != expectedURI
        case .skipForward(let previousURI, let expectedNextURI):
            if let expectedNextURI {
                return snapshot.reportedPlayingURI != expectedNextURI
            }
            if let previousURI {
                return snapshot.reportedPlayingURI == previousURI
            }
            return false
        case .skipBack(let previousURI):
            guard let previousURI else { return false }
            return snapshot.reportedPlayingURI == previousURI
        case .addToQueue(let uri, let previousMatchingCount):
            let count = snapshot.upcomingURIs.filter { $0 == uri }.count
            return count <= previousMatchingCount
        case .shuffle(let enabled):
            guard let actual = snapshot.shuffleState else { return false }
            return actual != enabled
        case .transfer(let deviceID):
            return snapshot.deviceID != deviceID
        }
    }
}
