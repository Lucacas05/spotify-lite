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
    static func isLocalPlayback(isLocalEngineRunning: Bool, activeDeviceName: String?) -> Bool {
        isLocalEngineRunning && activeDeviceName == LibrespotEngine.deviceName
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
