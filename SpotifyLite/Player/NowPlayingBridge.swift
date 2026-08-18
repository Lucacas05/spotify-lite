import AppKit
import Foundation
import MediaPlayer

protocol NowPlayingArtworkFetching: Sendable {
    func data(from url: URL) async throws -> Data
}

struct URLSessionArtworkFetcher: NowPlayingArtworkFetching {
    func data(from url: URL) async throws -> Data {
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }
}

@MainActor
final class NowPlayingArtworkLoader {
    private let fetcher: any NowPlayingArtworkFetching
    /// Bounded so long sessions do not retain every high-resolution cover.
    static let maxCachedArtworks = 8
    private var cache: [URL: Data] = [:]
    private(set) var currentTrackID: String?

    init(fetcher: any NowPlayingArtworkFetching = URLSessionArtworkFetcher()) {
        self.fetcher = fetcher
    }

    func cachedData(for url: URL) -> Data? {
        cache[url]
    }

    func setCurrentTrack(_ trackID: String?) {
        currentTrackID = trackID
    }

    func load(trackID: String, url: URL?) async -> Data? {
        guard let url else { return nil }
        if let cached = cache[url] {
            return NowPlayingArtworkGuard.shouldApply(
                loadedTrackID: trackID,
                currentTrackID: currentTrackID
            ) ? cached : nil
        }

        do {
            let data = try await fetcher.data(from: url)
            guard NowPlayingArtworkGuard.shouldApply(
                loadedTrackID: trackID,
                currentTrackID: currentTrackID
            ) else { return nil }
            if cache.count >= Self.maxCachedArtworks {
                cache.removeAll(keepingCapacity: true)
            }
            cache[url] = data
            return data
        } catch {
            return nil
        }
    }
}

@MainActor
protocol NowPlayingMediaCenter: AnyObject {
    var commandHandler: ((NowPlayingCommand) -> Void)? { get set }
    func publish(_ snapshot: NowPlayingSnapshot)
    func setPlaybackState(_ state: NowPlayingPlaybackState, rate: Double)
    func setCommandsEnabled(_ enabled: Bool)
    func clear()
}

@MainActor
final class SystemNowPlayingMediaCenter: NowPlayingMediaCenter {
    var commandHandler: ((NowPlayingCommand) -> Void)?

    private let infoCenter = MPNowPlayingInfoCenter.default()
    private let commandCenter = MPRemoteCommandCenter.shared()
    private var commandsEnabled = false

    init() {
        disableUnsupportedCommands()
        register(commandCenter.playCommand, as: .play)
        register(commandCenter.pauseCommand, as: .pause)
        register(commandCenter.togglePlayPauseCommand, as: .toggle)
        register(commandCenter.previousTrackCommand, as: .previous)
        register(commandCenter.nextTrackCommand, as: .next)
        setCommandsEnabled(false)
    }

    func publish(_ snapshot: NowPlayingSnapshot) {
        infoCenter.nowPlayingInfo = dictionary(from: snapshot)
        setPlaybackState(snapshot.playbackState, rate: snapshot.playbackRate)
    }

    func setPlaybackState(_ state: NowPlayingPlaybackState, rate: Double) {
        switch state {
        case .playing:
            infoCenter.playbackState = .playing
        case .paused:
            infoCenter.playbackState = .paused
        case .stopped:
            infoCenter.playbackState = .stopped
        }
        if var info = infoCenter.nowPlayingInfo {
            info[MPNowPlayingInfoPropertyPlaybackRate] = rate
            infoCenter.nowPlayingInfo = info
        }
    }

    func setCommandsEnabled(_ enabled: Bool) {
        commandsEnabled = enabled
        commandCenter.playCommand.isEnabled = enabled
        commandCenter.pauseCommand.isEnabled = enabled
        commandCenter.togglePlayPauseCommand.isEnabled = enabled
        commandCenter.previousTrackCommand.isEnabled = enabled
        commandCenter.nextTrackCommand.isEnabled = enabled
    }

    func clear() {
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
        setCommandsEnabled(false)
    }

    private func register(_ command: MPRemoteCommand, as nowPlayingCommand: NowPlayingCommand) {
        command.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.commandsEnabled else { return }
                self.commandHandler?(nowPlayingCommand)
            }
            return .success
        }
    }

    private func disableUnsupportedCommands() {
        let unsupported: [MPRemoteCommand] = [
            commandCenter.stopCommand,
            commandCenter.skipForwardCommand,
            commandCenter.skipBackwardCommand,
            commandCenter.seekForwardCommand,
            commandCenter.seekBackwardCommand,
            commandCenter.changePlaybackPositionCommand,
            commandCenter.changePlaybackRateCommand,
            commandCenter.changeRepeatModeCommand,
            commandCenter.changeShuffleModeCommand,
            commandCenter.likeCommand,
            commandCenter.enableLanguageOptionCommand,
            commandCenter.disableLanguageOptionCommand,
            commandCenter.dislikeCommand,
            commandCenter.bookmarkCommand,
            commandCenter.ratingCommand,
        ]
        for command in unsupported {
            command.isEnabled = false
            command.removeTarget(nil)
        }
    }

    private func dictionary(from snapshot: NowPlayingSnapshot) -> [String: Any]? {
        guard snapshot.trackID != nil else { return nil }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPMediaItemPropertyArtist: snapshot.artist,
            MPMediaItemPropertyAlbumTitle: snapshot.album,
            MPMediaItemPropertyPlaybackDuration: snapshot.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.playbackRate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let data = snapshot.artworkData, let image = NSImage(data: data) {
            let size = image.size
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: size) { _ in image }
        }
        return info
    }
}

@MainActor
final class NowPlayingBridge {
    var onCommand: ((NowPlayingCommand) -> Void)?

    private let mediaCenter: any NowPlayingMediaCenter
    private let artworkLoader: NowPlayingArtworkLoader
    private(set) var lastSnapshot: NowPlayingSnapshot?
    private(set) var commandsEnabled = false

    init(
        mediaCenter: (any NowPlayingMediaCenter)? = nil,
        artworkLoader: NowPlayingArtworkLoader? = nil
    ) {
        self.mediaCenter = mediaCenter ?? SystemNowPlayingMediaCenter()
        self.artworkLoader = artworkLoader ?? NowPlayingArtworkLoader()
        self.mediaCenter.commandHandler = { [weak self] command in
            self?.handle(command)
        }
    }

    func sync(
        isLocalEngineRunning: Bool,
        activeDeviceID: String?,
        localDeviceID: String?,
        track: Track?,
        progressMs: Int,
        isPlaying: Bool
    ) {
        let eligible = NowPlayingEligibility.shouldClaimSystemNowPlaying(
            isLocalEngineRunning: isLocalEngineRunning,
            activeDeviceID: activeDeviceID,
            localDeviceID: localDeviceID,
            hasTrack: track != nil
        )
        guard eligible else {
            clear()
            return
        }

        setCommandsEnabled(true)
        var snapshot = NowPlayingSnapshot.make(
            track: track,
            progressMs: progressMs,
            isPlaying: isPlaying
        )
        artworkLoader.setCurrentTrack(snapshot.trackID)
        if let url = snapshot.artworkURL, let cached = artworkLoader.cachedData(for: url) {
            snapshot.artworkData = cached
        }
        publish(snapshot)

        guard let trackID = snapshot.trackID,
              snapshot.artworkData == nil,
              snapshot.artworkURL != nil else { return }
        let requestedURL = snapshot.artworkURL
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let data = await self.artworkLoader.load(trackID: trackID, url: requestedURL) else { return }
            guard self.lastSnapshot?.trackID == trackID else { return }
            self.publish(self.lastSnapshot?.withArtwork(data) ?? snapshot.withArtwork(data))
        }
    }

    func clear() {
        artworkLoader.setCurrentTrack(nil)
        lastSnapshot = nil
        setCommandsEnabled(false)
        mediaCenter.clear()
    }

    func handle(_ command: NowPlayingCommand) {
        guard commandsEnabled else { return }
        applyOptimisticState(for: command)
        onCommand?(command)
    }

    private func applyOptimisticState(for command: NowPlayingCommand) {
        switch command {
        case .play:
            applyOptimisticPlayback(isPlaying: true)
        case .pause:
            applyOptimisticPlayback(isPlaying: false)
        case .toggle:
            applyOptimisticPlayback(isPlaying: !(lastSnapshot?.isPlaying ?? false))
        case .previous, .next:
            break
        }
    }

    private func applyOptimisticPlayback(isPlaying: Bool) {
        if let snapshot = lastSnapshot, snapshot.trackID != nil {
            publish(snapshot.withPlayback(isPlaying: isPlaying))
        } else {
            mediaCenter.setPlaybackState(isPlaying ? .playing : .paused, rate: isPlaying ? 1 : 0)
        }
    }

    private func publish(_ snapshot: NowPlayingSnapshot) {
        lastSnapshot = snapshot
        mediaCenter.publish(snapshot)
    }

    private func setCommandsEnabled(_ enabled: Bool) {
        commandsEnabled = enabled
        mediaCenter.setCommandsEnabled(enabled)
    }
}
