import Foundation

/// Commands that can change Spotify's reported queue or currently-playing item.
enum PlaybackMutation: Equatable {
    case play(expectedURI: String?)
    case setPlaying(Bool)
    case skipForward(previousURI: String?, expectedNextURI: String?)
    case skipBack(previousURI: String?)
    case addToQueue(uri: String, previousMatchingCount: Int)
    case shuffle(enabled: Bool)
    case setVolume(percent: Int)
    case transfer(deviceID: String)

    /// Queue-changing intents that still use the #11 playback/queue coordinator.
    /// Transport commands confirm from the mutation HTTP. They do not issue a
    /// fresh GET /me/player; the existing poll catches up the UI.
    var requiresPlaybackAndQueueSync: Bool {
        switch self {
        case .addToQueue, .play, .transfer:
            return true
        case .setPlaying, .skipForward, .skipBack, .shuffle, .setVolume:
            return false
        }
    }

    /// Successful next/previous are confirmed by the mutation HTTP. A later
    /// poll that still shows the previous track is stale, not a silent revert.
    var ignoresStalePollAfterSuccess: Bool {
        playingURIToIgnoreAfterSuccess != nil
    }

    /// URI we just left. Polls that still report it must not undo a skip,
    /// even if a later play/pause overwrites `pendingPollConfirmation`.
    var playingURIToIgnoreAfterSuccess: String? {
        switch self {
        case .skipForward(let previousURI, _), .skipBack(let previousURI):
            return previousURI
        case .play, .setPlaying, .addToQueue, .shuffle, .setVolume, .transfer:
            return nil
        }
    }
}

/// Flattened playback + queue view used to decide whether Spotify has caught up.
struct PlaybackQueueSnapshot: Equatable {
    var playingURI: String?
    var isPlaying: Bool?
    var volumePercent: Int?
    var shuffleState: Bool?
    var deviceID: String?
    var currentlyPlayingURI: String?
    var upcomingURIs: [String]

    init(
        playingURI: String? = nil,
        isPlaying: Bool? = nil,
        volumePercent: Int? = nil,
        shuffleState: Bool? = nil,
        deviceID: String? = nil,
        currentlyPlayingURI: String? = nil,
        upcomingURIs: [String] = []
    ) {
        self.playingURI = playingURI
        self.isPlaying = isPlaying
        self.volumePercent = volumePercent
        self.shuffleState = shuffleState
        self.deviceID = deviceID
        self.currentlyPlayingURI = currentlyPlayingURI
        self.upcomingURIs = upcomingURIs
    }

    init(playback: PlaybackState?, currentlyPlaying: Track?, upcoming: [Track]) {
        self.init(
            playingURI: playback?.item?.uri,
            isPlaying: playback?.isPlaying,
            volumePercent: playback?.device?.volumePercent,
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

    /// Gate used by `PlayerStore.refresh()`. A skip URI stays ignored even
    /// when the pending mutation is a later play/pause/seek.
    static func shouldApplyPlaybackPoll(
        _ snapshot: PlaybackQueueSnapshot,
        pendingMutation: PlaybackMutation?,
        ignoringPlayingURI: String?,
        now: Date,
        deadline: Date?
    ) -> Bool {
        var pendingMutation = pendingMutation
        if let ignoringPlayingURI {
            guard let reported = snapshot.reportedPlayingURI,
                  reported != ignoringPlayingURI else {
                return false
            }
            // Poll already left the skipped URI. A leftover skipForward
            // mutation still looks "stale" against that old URI and must
            // not block Previous (or another skip) from catching up.
            if pendingMutation?.ignoresStalePollAfterSuccess == true {
                pendingMutation = nil
            }
        }
        guard let pendingMutation, let deadline else {
            return true
        }
        return shouldApplyRemote(
            snapshot, after: pendingMutation, now: now, deadline: deadline
        )
    }

    /// After HTTP success, the existing 5s/30s poll may catch up. A skip that
    /// already succeeded must not be undone by a superseded GET /me/player.
    static func shouldApplyRemote(
        _ snapshot: PlaybackQueueSnapshot,
        after mutation: PlaybackMutation,
        now: Date,
        deadline: Date
    ) -> Bool {
        if !isStale(snapshot, after: mutation) {
            return true
        }
        if mutation.ignoresStalePollAfterSuccess {
            return false
        }
        return now >= deadline
    }

    static func confirmationDeadline(now: Date, pollIntervalSeconds: Int) -> Date {
        now.addingTimeInterval(TimeInterval(max(pollIntervalSeconds, 0)))
    }

    static func isStale(_ snapshot: PlaybackQueueSnapshot, after mutation: PlaybackMutation) -> Bool {
        switch mutation {
        case .play(let expectedURI):
            guard let expectedURI else { return false }
            return snapshot.reportedPlayingURI != expectedURI
        case .setPlaying(let expected):
            return (snapshot.isPlaying ?? false) != expected
        case .setVolume(let percent):
            guard let actual = snapshot.volumePercent else { return false }
            return actual != percent
        case .skipForward(let previousURI, _):
            guard let previousURI else { return false }
            return snapshot.reportedPlayingURI == previousURI
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
