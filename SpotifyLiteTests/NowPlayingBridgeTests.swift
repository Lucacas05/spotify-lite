import XCTest
@testable import SpotifyLite

@MainActor
final class FakeNowPlayingMediaCenter: NowPlayingMediaCenter {
    var commandHandler: ((NowPlayingCommand) -> Void)?
    private(set) var published: [NowPlayingSnapshot] = []
    private(set) var playbackUpdates: [(NowPlayingPlaybackState, Double)] = []
    private(set) var commandsEnabledHistory: [Bool] = []
    private(set) var currentSnapshot: NowPlayingSnapshot?
    private(set) var commandsEnabled = false
    private(set) var clearCount = 0

    func publish(_ snapshot: NowPlayingSnapshot) {
        published.append(snapshot)
        currentSnapshot = snapshot
        setPlaybackState(snapshot.playbackState, rate: snapshot.playbackRate)
    }

    func setPlaybackState(_ state: NowPlayingPlaybackState, rate: Double) {
        playbackUpdates.append((state, rate))
    }

    func setCommandsEnabled(_ enabled: Bool) {
        commandsEnabled = enabled
        commandsEnabledHistory.append(enabled)
    }

    func clear() {
        clearCount += 1
        currentSnapshot = nil
        commandsEnabled = false
        setPlaybackState(.stopped, rate: 0)
    }

    func emit(_ command: NowPlayingCommand) {
        commandHandler?(command)
    }
}

actor ControllableArtworkFetcher: NowPlayingArtworkFetching {
    private var pending: [URL: CheckedContinuation<Data, Error>] = [:]
    private var startedWaiters: [URL: CheckedContinuation<Void, Never>] = [:]
    private var startedURLs: Set<URL> = []

    func waitUntilStarted(_ url: URL) async {
        if startedURLs.contains(url) { return }
        await withCheckedContinuation { startedWaiters[url] = $0 }
    }

    func complete(_ url: URL, data: Data) {
        pending[url]?.resume(returning: data)
        pending[url] = nil
    }

    func data(from url: URL) async throws -> Data {
        startedURLs.insert(url)
        startedWaiters[url]?.resume()
        startedWaiters[url] = nil
        return try await withCheckedThrowingContinuation { pending[url] = $0 }
    }
}

@MainActor
final class NowPlayingBridgeTests: XCTestCase {
    private func makeTrack(
        id: String = "track-1",
        name: String = "Test Track",
        artists: [String] = ["First Artist", "Second Artist"],
        album: String = "Test Album",
        durationMs: Int = 185_000,
        images: [(String, Int)] = [
            ("https://example.com/large.jpg", 640),
            ("https://example.com/small.jpg", 64),
        ]
    ) -> Track {
        Track(
            id: id,
            name: name,
            uri: "spotify:track:\(id)",
            durationMs: durationMs,
            artists: artists.enumerated().map { Artist(id: "artist-\($0.offset)", name: $0.element) },
            album: Album(
                id: "album-1",
                name: album,
                images: images.map { SpotifyImage(url: $0.0, width: $0.1, height: $0.1) }
            )
        )
    }

    private func makeBridge(
        mediaCenter: FakeNowPlayingMediaCenter? = nil,
        loader: NowPlayingArtworkLoader? = nil
    ) -> (NowPlayingBridge, FakeNowPlayingMediaCenter) {
        let mediaCenter = mediaCenter ?? FakeNowPlayingMediaCenter()
        let loader = loader ?? NowPlayingArtworkLoader(fetcher: ImmediateArtworkFetcher())
        return (NowPlayingBridge(mediaCenter: mediaCenter, artworkLoader: loader), mediaCenter)
    }

    func testPlayingSnapshotPublishesMetadataRateAndAudioType() {
        let snapshot = NowPlayingSnapshot.make(
            track: makeTrack(),
            progressMs: 15_000,
            isPlaying: true
        )

        XCTAssertEqual(snapshot.trackID, "track-1")
        XCTAssertEqual(snapshot.title, "Test Track")
        XCTAssertEqual(snapshot.artist, "First Artist, Second Artist")
        XCTAssertEqual(snapshot.album, "Test Album")
        XCTAssertEqual(snapshot.duration, 185)
        XCTAssertEqual(snapshot.elapsed, 15)
        XCTAssertEqual(snapshot.artworkURL?.absoluteString, "https://example.com/large.jpg")
        XCTAssertEqual(snapshot.playbackRate, 1)
        XCTAssertEqual(snapshot.playbackState, .playing)
        XCTAssertEqual(snapshot.mediaType, .audio)
    }

    func testPausedSnapshotHasZeroRate() {
        let snapshot = NowPlayingSnapshot.make(
            track: makeTrack(),
            progressMs: 20_000,
            isPlaying: false
        )

        XCTAssertEqual(snapshot.playbackRate, 0)
        XCTAssertEqual(snapshot.playbackState, .paused)
        XCTAssertEqual(snapshot.elapsed, 20)
    }

    func testLocalDeviceEligibilityRequiresEngineAndSpotifyLiteDevice() {
        XCTAssertTrue(
            NowPlayingEligibility.isLocalPlayback(
                isLocalEngineRunning: true,
                activeDeviceName: LibrespotEngine.deviceName
            )
        )
        XCTAssertFalse(
            NowPlayingEligibility.isLocalPlayback(
                isLocalEngineRunning: true,
                activeDeviceName: "iPhone"
            )
        )
        XCTAssertFalse(
            NowPlayingEligibility.isLocalPlayback(
                isLocalEngineRunning: false,
                activeDeviceName: LibrespotEngine.deviceName
            )
        )
        XCTAssertFalse(
            NowPlayingEligibility.isLocalPlayback(
                isLocalEngineRunning: true,
                activeDeviceName: nil
            )
        )
    }

    func testBridgeClaimsNowPlayingOnlyForLocalSpotifyLitePlayback() {
        let (bridge, fake) = makeBridge()
        let track = makeTrack()

        bridge.sync(
            isLocalEngineRunning: true,
            activeDeviceName: LibrespotEngine.deviceName,
            track: track,
            progressMs: 1_000,
            isPlaying: true
        )

        XCTAssertTrue(fake.commandsEnabled)
        XCTAssertEqual(fake.currentSnapshot?.title, "Test Track")
        XCTAssertEqual(fake.currentSnapshot?.playbackState, .playing)
    }

    func testDeviceTransferClearsMetadataAndDisablesCommands() {
        let (bridge, fake) = makeBridge()

        bridge.sync(
            isLocalEngineRunning: true,
            activeDeviceName: LibrespotEngine.deviceName,
            track: makeTrack(),
            progressMs: 1_000,
            isPlaying: true
        )
        XCTAssertTrue(fake.commandsEnabled)

        bridge.sync(
            isLocalEngineRunning: true,
            activeDeviceName: "iPhone",
            track: makeTrack(),
            progressMs: 1_000,
            isPlaying: true
        )

        XCTAssertFalse(fake.commandsEnabled)
        XCTAssertNil(fake.currentSnapshot)
        XCTAssertGreaterThanOrEqual(fake.clearCount, 1)
        XCTAssertEqual(fake.playbackUpdates.last?.0, .stopped)
    }

    func testStoppingLocalPlaybackClearsNowPlaying() {
        let (bridge, fake) = makeBridge()
        bridge.sync(
            isLocalEngineRunning: true,
            activeDeviceName: LibrespotEngine.deviceName,
            track: makeTrack(),
            progressMs: 1_000,
            isPlaying: true
        )

        bridge.sync(
            isLocalEngineRunning: false,
            activeDeviceName: LibrespotEngine.deviceName,
            track: makeTrack(),
            progressMs: 1_000,
            isPlaying: false
        )

        XCTAssertFalse(fake.commandsEnabled)
        XCTAssertNil(fake.currentSnapshot)
        XCTAssertGreaterThanOrEqual(fake.clearCount, 1)
    }

    func testBackgroundPollingContinuesOnlyWhileSpotifyLiteIsActive() {
        XCTAssertEqual(
            PlaybackPollingPolicy.intervalSeconds(
                isPlaying: true, isSceneActive: true, isLocalDeviceActive: false),
            5
        )
        XCTAssertEqual(
            PlaybackPollingPolicy.intervalSeconds(
                isPlaying: false, isSceneActive: true, isLocalDeviceActive: false),
            30
        )
        XCTAssertEqual(
            PlaybackPollingPolicy.intervalSeconds(
                isPlaying: true, isSceneActive: false, isLocalDeviceActive: true),
            30
        )
        XCTAssertEqual(
            PlaybackPollingPolicy.intervalSeconds(
                isPlaying: false, isSceneActive: false, isLocalDeviceActive: true),
            30
        )
        XCTAssertNil(
            PlaybackPollingPolicy.intervalSeconds(
                isPlaying: true, isSceneActive: false, isLocalDeviceActive: false)
        )
    }

    func testStaleArtworkIsDiscardedWhenTrackChanges() {
        XCTAssertTrue(NowPlayingArtworkGuard.shouldApply(loadedTrackID: "a", currentTrackID: "a"))
        XCTAssertFalse(NowPlayingArtworkGuard.shouldApply(loadedTrackID: "a", currentTrackID: "b"))
        XCTAssertFalse(NowPlayingArtworkGuard.shouldApply(loadedTrackID: "a", currentTrackID: nil))
    }

    func testArtworkLoaderDropsStaleResponseForANewerTrack() async {
        let fetcher = ControllableArtworkFetcher()
        let loader = NowPlayingArtworkLoader(fetcher: fetcher)
        let urlA = URL(string: "https://example.com/a.jpg")!
        let urlB = URL(string: "https://example.com/b.jpg")!

        loader.setCurrentTrack("a")
        let taskA = Task { @MainActor in await loader.load(trackID: "a", url: urlA) }
        await fetcher.waitUntilStarted(urlA)

        loader.setCurrentTrack("b")
        let taskB = Task { @MainActor in await loader.load(trackID: "b", url: urlB) }
        await fetcher.waitUntilStarted(urlB)

        await fetcher.complete(urlA, data: Data("A".utf8))
        await fetcher.complete(urlB, data: Data("B".utf8))

        let resultA = await taskA.value
        let resultB = await taskB.value

        XCTAssertNil(resultA)
        XCTAssertEqual(resultB, Data("B".utf8))
    }

    func testEachSystemCommandDispatchesExactlyOnePlayerStoreAction() {
        let (bridge, fake) = makeBridge()
        var actions: [NowPlayingCommand] = []
        bridge.onCommand = { actions.append($0) }

        bridge.sync(
            isLocalEngineRunning: true,
            activeDeviceName: LibrespotEngine.deviceName,
            track: makeTrack(),
            progressMs: 1_000,
            isPlaying: true
        )

        fake.emit(.play)
        fake.emit(.pause)
        fake.emit(.toggle)
        fake.emit(.previous)
        fake.emit(.next)

        XCTAssertEqual(actions, [.play, .pause, .toggle, .previous, .next])
    }

    func testPlayCommandUpdatesExpectedPlaybackStateImmediately() {
        let (bridge, fake) = makeBridge()
        bridge.sync(
            isLocalEngineRunning: true,
            activeDeviceName: LibrespotEngine.deviceName,
            track: makeTrack(),
            progressMs: 8_000,
            isPlaying: false
        )

        fake.emit(.play)

        XCTAssertEqual(fake.currentSnapshot?.isPlaying, true)
        XCTAssertEqual(fake.currentSnapshot?.playbackRate, 1)
        XCTAssertEqual(fake.currentSnapshot?.playbackState, .playing)
    }

    func testCommandsAreIgnoredOutsideLocalPlayback() {
        let (bridge, fake) = makeBridge()
        var actions: [NowPlayingCommand] = []
        bridge.onCommand = { actions.append($0) }

        bridge.sync(
            isLocalEngineRunning: true,
            activeDeviceName: "iPhone",
            track: makeTrack(),
            progressMs: 1_000,
            isPlaying: true
        )

        fake.emit(.play)
        fake.emit(.next)

        XCTAssertTrue(actions.isEmpty)
        XCTAssertFalse(fake.commandsEnabled)
    }
}

private struct ImmediateArtworkFetcher: NowPlayingArtworkFetching {
    func data(from url: URL) async throws -> Data {
        Data(url.absoluteString.utf8)
    }
}
