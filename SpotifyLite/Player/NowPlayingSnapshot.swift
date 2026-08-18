import Foundation

enum NowPlayingCommand: Equatable {
    case play
    case pause
    case toggle
    case previous
    case next
}

enum NowPlayingPlaybackState: Equatable {
    case playing
    case paused
    case stopped
}

enum NowPlayingMediaType: Equatable {
    case audio
}

enum NowPlayingEligibility {
    /// Ownership is the exact local Connect device id, not the name "SpotifyLite".
    static func ownsActiveDevice(activeDeviceID: String?, localDeviceID: String?) -> Bool {
        guard let activeDeviceID, !activeDeviceID.isEmpty,
              let localDeviceID, !localDeviceID.isEmpty else { return false }
        return activeDeviceID == localDeviceID
    }

    static func isLocalPlayback(
        isLocalEngineRunning: Bool,
        activeDeviceID: String?,
        localDeviceID: String?
    ) -> Bool {
        isLocalEngineRunning && ownsActiveDevice(
            activeDeviceID: activeDeviceID,
            localDeviceID: localDeviceID
        )
    }

    /// 204 / no track must release the system Now Playing lock.
    static func shouldClaimSystemNowPlaying(
        isLocalEngineRunning: Bool,
        activeDeviceID: String?,
        localDeviceID: String?,
        hasTrack: Bool
    ) -> Bool {
        hasTrack && isLocalPlayback(
            isLocalEngineRunning: isLocalEngineRunning,
            activeDeviceID: activeDeviceID,
            localDeviceID: localDeviceID
        )
    }
}

enum NowPlayingArtworkGuard {
    static func shouldApply(loadedTrackID: String, currentTrackID: String?) -> Bool {
        loadedTrackID == currentTrackID
    }
}

/// Testable Now Playing payload. Does not import MediaPlayer.
struct NowPlayingSnapshot: Equatable {
    var trackID: String?
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var elapsed: TimeInterval
    var artworkURL: URL?
    var artworkData: Data?
    var isPlaying: Bool
    var mediaType: NowPlayingMediaType

    var playbackRate: Double { isPlaying ? 1.0 : 0.0 }

    var playbackState: NowPlayingPlaybackState {
        guard trackID != nil else { return .stopped }
        return isPlaying ? .playing : .paused
    }

    func withArtwork(_ data: Data?) -> NowPlayingSnapshot {
        var copy = self
        copy.artworkData = data
        return copy
    }

    func withPlayback(isPlaying: Bool) -> NowPlayingSnapshot {
        var copy = self
        copy.isPlaying = isPlaying
        return copy
    }

    static func empty() -> NowPlayingSnapshot {
        NowPlayingSnapshot(
            trackID: nil,
            title: "",
            artist: "",
            album: "",
            duration: 0,
            elapsed: 0,
            artworkURL: nil,
            artworkData: nil,
            isPlaying: false,
            mediaType: .audio
        )
    }

    static func make(track: Track?, progressMs: Int, isPlaying: Bool) -> NowPlayingSnapshot {
        guard let track else { return .empty() }
        let durationMs = max(track.durationMs, 0)
        let elapsedMs = min(max(progressMs, 0), durationMs)
        return NowPlayingSnapshot(
            trackID: track.id ?? track.uri,
            title: track.name,
            artist: track.artistNames,
            album: track.album?.name ?? "",
            duration: TimeInterval(durationMs) / 1000,
            elapsed: TimeInterval(elapsedMs) / 1000,
            artworkURL: track.highResolutionArtworkURL,
            artworkData: nil,
            isPlaying: isPlaying,
            mediaType: .audio
        )
    }
}
