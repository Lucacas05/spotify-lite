import Foundation
import Observation

enum PlaybackPollingPolicy {
    static let foregroundPlayingIntervalSeconds = 5
    static let foregroundIdleIntervalSeconds = 30
    static let backgroundLocalPlaybackIntervalSeconds = 30

    static func intervalSeconds(isPlaying: Bool) -> Int {
        isPlaying ? foregroundPlayingIntervalSeconds : foregroundIdleIntervalSeconds
    }

    /// `nil` means polling should stop. Background polling continues at 30 s
    /// only while the last confirmed active device is SpotifyLite.
    static func intervalSeconds(
        isPlaying: Bool,
        isSceneActive: Bool,
        isLocalDeviceActive: Bool
    ) -> Int? {
        if isSceneActive {
            return intervalSeconds(isPlaying: isPlaying)
        }
        guard isLocalDeviceActive else { return nil }
        return backgroundLocalPlaybackIntervalSeconds
    }
}

struct PlaybackProgressState {
    struct PendingSeek {
        let trackID: String?
        let targetMs: Int
        let createdAt: Date
    }

    private(set) var trackID: String?
    private(set) var durationMs: Int = 0
    private var anchorProgressMs: Int = 0
    private var anchorDate: Date = .distantPast
    private(set) var isPlaying = false
    private(set) var pendingSeek: PendingSeek?

    mutating func applyRemoteState(
        trackID: String?,
        durationMs: Int?,
        progressMs: Int?,
        isPlaying: Bool,
        receivedAt: Date
    ) {
        let normalizedDuration = max(durationMs ?? 0, 0)
        let normalizedProgress = clamp(progressMs ?? 0, durationMs: normalizedDuration)
        let didTrackChange = self.trackID != trackID

        if didTrackChange {
            pendingSeek = nil
            setAnchor(
                trackID: trackID,
                durationMs: normalizedDuration,
                progressMs: normalizedProgress,
                isPlaying: isPlaying,
                at: receivedAt
            )
            return
        }

        if let pendingSeek, shouldHoldPendingSeek(pendingSeek, remoteProgressMs: normalizedProgress, at: receivedAt) {
            self.durationMs = normalizedDuration
            if self.isPlaying != isPlaying {
                let frozenProgress = progress(at: receivedAt)
                anchorProgressMs = clamp(frozenProgress, durationMs: normalizedDuration)
                anchorDate = receivedAt
            }
            self.isPlaying = isPlaying
            return
        }

        pendingSeek = nil
        setAnchor(
            trackID: trackID,
            durationMs: normalizedDuration,
            progressMs: normalizedProgress,
            isPlaying: isPlaying,
            at: receivedAt
        )
    }

    mutating func applyLocalSeek(
        trackID: String?,
        durationMs: Int?,
        targetMs: Int,
        isPlaying: Bool,
        at date: Date
    ) {
        let normalizedDuration = max(durationMs ?? 0, 0)
        let target = clamp(targetMs, durationMs: normalizedDuration)
        self.trackID = trackID
        self.durationMs = normalizedDuration
        self.anchorProgressMs = target
        self.anchorDate = date
        self.isPlaying = isPlaying
        self.pendingSeek = PendingSeek(trackID: trackID, targetMs: target, createdAt: date)
    }

    mutating func cancelPendingSeek() {
        pendingSeek = nil
    }

    mutating func applyPlaybackStatus(isPlaying: Bool, at date: Date) {
        let current = progress(at: date)
        anchorProgressMs = clamp(current, durationMs: durationMs)
        anchorDate = date
        self.isPlaying = isPlaying
    }

    func progress(at date: Date) -> Int {
        guard durationMs > 0 else { return 0 }
        guard isPlaying else { return clamp(anchorProgressMs, durationMs: durationMs) }
        let elapsedMs = max(Int(date.timeIntervalSince(anchorDate) * 1000), 0)
        return clamp(anchorProgressMs + elapsedMs, durationMs: durationMs)
    }

    private mutating func setAnchor(
        trackID: String?,
        durationMs: Int,
        progressMs: Int,
        isPlaying: Bool,
        at date: Date
    ) {
        self.trackID = trackID
        self.durationMs = durationMs
        self.anchorProgressMs = clamp(progressMs, durationMs: durationMs)
        self.anchorDate = date
        self.isPlaying = isPlaying
    }

    private func shouldHoldPendingSeek(_ pendingSeek: PendingSeek, remoteProgressMs: Int, at date: Date) -> Bool {
        guard pendingSeek.trackID == trackID else { return false }
        let pendingAge = date.timeIntervalSince(pendingSeek.createdAt)
        guard pendingAge < 3 else { return false }
        // Compare against the interpolated position, not the original target:
        // if Spotify already applied the seek, the remote advances with time
        // and would drift away from the target even when confirmation is correct.
        let delta = abs(remoteProgressMs - progress(at: date))
        return delta > 1_500
    }

    private func clamp(_ progressMs: Int, durationMs: Int) -> Int {
        guard durationMs > 0 else { return 0 }
        return min(max(progressMs, 0), durationMs)
    }
}

@MainActor
@Observable
final class PlayerStore {
    private(set) var state: PlaybackState?
    private(set) var devices: [Device] = []
    var lastError: String?
    /// True when local playback needs librespot installed — drives the setup sheet.
    var localSetupNeeded = false
    /// Optimistic volume so keyboard +/- update the slider without waiting for poll.
    var volumePercent: Int = 50

    let localEngine = LibrespotEngine()
    @ObservationIgnored
    let nowPlaying: NowPlayingBridge

    private var pollTask: Task<Void, Never>?
    private var pollGeneration = 0
    private var progressState = PlaybackProgressState()
    private var seekRequestID = 0
    private var queueState = QueueRefreshState()
    private var queueLoadTask: Task<Void, Never>?
    private var playbackSyncTask: Task<Void, Never>?

    var queue: [Track] { queueState.upcoming }
    var queueRows: [QueueRowItem] { queueState.rows }
    var queueIsLoading: Bool { queueState.isLoading }
    var queueError: String? { queueState.lastError }
    var queuePresentation: QueuePresentation { queueState.presentation }

    private var isSceneActive = false
    /// Connect device id of the librespot instance we launched. Ownership of
    /// Now Playing uses this id, not the advertised name "SpotifyLite".
    private(set) var localDeviceID: String?
    private(set) var lastConfirmedDeviceID: String?

    init(nowPlaying: NowPlayingBridge? = nil) {
        self.nowPlaying = nowPlaying ?? NowPlayingBridge()
        self.nowPlaying.onCommand = { [weak self] command in
            Task { await self?.handleNowPlayingCommand(command) }
        }
        // Surface asynchronous engine deaths (crash-restart budget exhausted)
        // as a banner; the app keeps working in remote-control mode.
        localEngine.onUnrecoverableFailure = { [weak self] message in
            self?.forgetLocalPlaybackSession()
            self?.lastError = message
            self?.publishNowPlaying()
            self?.reconcilePolling()
        }
        localEngine.onBecameRunning = { [weak self] in
            Task { await self?.handleEngineBecameRunning() }
        }
    }

    var currentTrackIdentifier: String? {
        state?.item?.id ?? state?.item?.uri
    }

    var isShuffling: Bool {
        state?.shuffleState ?? false
    }

    var isLocalDeviceActive: Bool {
        NowPlayingEligibility.ownsActiveDevice(
            activeDeviceID: lastConfirmedDeviceID,
            localDeviceID: localDeviceID
        )
    }

    func setSceneActive(_ active: Bool) {
        let changed = isSceneActive != active
        isSceneActive = active
        guard changed else { return }
        if active {
            // A background 30 s poll may be mid-sleep; restart so the
            // foreground 5 s cadence applies immediately.
            stopPolling()
        }
        reconcilePolling()
    }

    func startPolling() {
        guard pollTask == nil else { return }
        guard nextPollIntervalSeconds() != nil else { return }
        pollGeneration += 1
        let generation = pollGeneration
        pollTask = Task {
            while !Task.isCancelled {
                await refresh()
                guard let seconds = nextPollIntervalSeconds() else { break }
                try? await Task.sleep(for: .seconds(seconds))
            }
            if pollGeneration == generation {
                pollTask = nil
            }
        }
    }

    func stopPolling() {
        pollGeneration += 1
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        do {
            let refreshedState: PlaybackState? = try await SpotifyClient.shared.getOptional("me/player")
            state = refreshedState
            updateLastConfirmedDevice(from: refreshedState)
            let now = Date()
            progressState.applyRemoteState(
                trackID: refreshedState?.item?.id ?? refreshedState?.item?.uri,
                durationMs: refreshedState?.item?.durationMs,
                progressMs: refreshedState?.progressMs,
                isPlaying: refreshedState?.isPlaying ?? false,
                receivedAt: now
            )
            if let volume = refreshedState?.device?.volumePercent {
                volumePercent = volume
            }
            lastError = nil
            publishNowPlaying()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadDevices() async {
        let response: DevicesResponse? = try? await SpotifyClient.shared.getOptional("me/player/devices")
        devices = response?.devices ?? []
    }

    func play() async {
        progressState.applyPlaybackStatus(isPlaying: true, at: Date())
        publishNowPlaying()
        await run { try await SpotifyClient.shared.command("PUT", "me/player/play") }
    }

    func pause() async {
        progressState.applyPlaybackStatus(isPlaying: false, at: Date())
        publishNowPlaying()
        await run { try await SpotifyClient.shared.command("PUT", "me/player/pause") }
    }

    func togglePlayPause() async {
        if progressState.isPlaying {
            await pause()
        } else {
            await play()
        }
    }

    func handleNowPlayingCommand(_ command: NowPlayingCommand) async {
        switch command {
        case .play:
            await play()
        case .pause:
            await pause()
        case .toggle:
            await togglePlayPause()
        case .previous:
            await previous()
        case .next:
            await next()
        }
    }

    func next() async {
        let mutation = PlaybackMutation.skipForward(
            previousURI: state?.item?.uri,
            expectedNextURI: queue.first?.uri
        )
        await run(mutation: mutation) {
            try await SpotifyClient.shared.command("POST", "me/player/next")
        }
    }

    func loadQueue(force: Bool = false) async {
        if let existing = queueLoadTask, !force {
            await existing.value
            return
        }
        var nextState = queueState
        guard let generation = nextState.beginRefresh(force: force) else {
            queueState = nextState
            await queueLoadTask?.value
            return
        }
        queueState = nextState
        let task = Task { await self.performQueueFetch(generation: generation) }
        queueLoadTask = task
        await task.value
        if queueLoadTask == task {
            queueLoadTask = nil
        }
    }

    func playNext(_ track: Track) async {
        let previousMatchingCount = queue.filter { $0.uri == track.uri }.count
        await run(mutation: .addToQueue(uri: track.uri, previousMatchingCount: previousMatchingCount)) {
            try await SpotifyClient.shared.command(
                "POST", "me/player/queue", query: ["uri": track.uri])
        }
    }

    func previous() async {
        await run(mutation: .skipBack(previousURI: state?.item?.uri)) {
            try await SpotifyClient.shared.command("POST", "me/player/previous")
        }
    }

    func setShuffle(_ enabled: Bool) async {
        await run(mutation: .shuffle(enabled: enabled)) {
            try await SpotifyClient.shared.command(
                "PUT", "me/player/shuffle", query: ["state": enabled ? "true" : "false"])
        }
    }

    func toggleShuffle() async {
        await setShuffle(!isShuffling)
    }

    func seek(to positionMs: Int, expectedTrackID: String? = nil) async {
        guard let durationMs = state?.item?.durationMs, durationMs > 0 else { return }
        let expectedTrackID = expectedTrackID ?? currentTrackIdentifier
        guard expectedTrackID == currentTrackIdentifier else { return }

        let now = Date()
        let isPlaying = progressState.isPlaying
        progressState.applyLocalSeek(
            trackID: expectedTrackID,
            durationMs: durationMs,
            targetMs: positionMs,
            isPlaying: isPlaying,
            at: now
        )

        seekRequestID += 1
        let requestID = seekRequestID
        let normalizedPosition = progressState.progress(at: now)
        guard expectedTrackID == currentTrackIdentifier else {
            progressState.cancelPendingSeek()
            return
        }

        do {
            try await SpotifyClient.shared.command(
                "PUT",
                "me/player/seek",
                query: ["position_ms": String(normalizedPosition)]
            )
            guard requestID == seekRequestID else { return }
            lastError = nil
            try? await Task.sleep(for: .milliseconds(350))
            await refresh()
        } catch is CancellationError {
            if requestID == seekRequestID {
                progressState.cancelPendingSeek()
            }
        } catch {
            guard requestID == seekRequestID else { return }
            progressState.cancelPendingSeek()
            lastError = friendlyMessage(for: error)
            await refresh()
        }
    }

    func setVolume(_ percent: Int) async {
        volumePercent = min(100, max(0, percent))
        await run(refreshAfter: false) {
            try await SpotifyClient.shared.command("PUT", "me/player/volume",
                                                   query: ["volume_percent": String(volumePercent)])
        }
    }

    func bumpVolume(_ delta: Int) async {
        await setVolume(volumePercent + delta)
    }

    func seekBy(seconds: Int) async {
        let target = progress(at: Date()) + seconds * 1000
        await seek(to: target)
    }

    func transferPlayback(to device: Device) async {
        guard let id = device.id else { return }
        await run(mutation: .transfer(deviceID: id)) {
            try await SpotifyClient.shared.command("PUT", "me/player", body: ["device_ids": [id]])
        }
    }

    /// Starts the local librespot engine and moves playback to this Mac, so the
    /// app works standalone with no official Spotify client open anywhere.
    func playOnThisMac() async {
        guard let device = await ensureLocalDevice() else { return }
        await transferPlayback(to: device)
        reconcilePolling()
    }

    /// Starts librespot (if needed) and waits until it registers as a Connect
    /// device. Returns the device, or nil after setting `lastError`.
    private func ensureLocalDevice() async -> Device? {
        await localEngine.start()
        guard localEngine.isRunning else {
            if localEngine.isNotInstalled {
                // Missing binary is a setup task, not an error: show the
                // install sheet instead of the red banner.
                localSetupNeeded = true
            } else if case .failed(let message) = localEngine.status {
                lastError = message
            }
            return nil
        }

        // The new Connect device takes a moment to register with Spotify —
        // longer on first run, when the user still has to approve access in
        // the browser that librespot's OAuth flow just opened.
        let attempts = localEngine.needsAuthorization ? 60 : 10
        for attempt in 0..<attempts {
            await loadDevices()
            if let device = localConnectDevice(from: devices) {
                localDeviceID = device.id
                return device
            }
            if !localEngine.isRunning { break }
            try? await Task.sleep(for: .seconds(attempt == 0 ? 1.5 : 1))
        }
        if case .failed(let message) = localEngine.status {
            lastError = message
        } else {
            lastError = "The local player started but never showed up as a Spotify device. Try again."
        }
        return nil
    }

    func stopLocalPlayback() {
        localEngine.stop()
        forgetLocalPlaybackSession()
        publishNowPlaying()
        reconcilePolling()
    }

    /// True when the banner message came from the local engine, so the
    /// banner can offer a one-click "Retry" that restarts local playback.
    func canRetryLocalPlayback(for message: String) -> Bool {
        if case .failed(let engineMessage) = localEngine.status {
            return engineMessage == message
        }
        return false
    }

    func handleSignOut() {
        stopLocalPlayback()
        stopPolling()
        state = nil
        nowPlaying.clear()
    }

    func play(contextURI: String?, trackURI: String? = nil) async {
        await playContext(contextURI: contextURI, trackURI: trackURI, uris: nil)
    }

    func play(trackURI: String) async {
        await playContext(contextURI: nil, trackURI: trackURI, uris: nil)
    }

    func play(uris: [String]) async {
        await playContext(contextURI: nil, trackURI: nil, uris: uris)
    }

    /// Play a context (playlist/album) starting at a track, or loose tracks.
    private func playContext(contextURI: String?, trackURI: String?, uris: [String]?) async {
        var body: [String: Any] = [:]
        if let contextURI {
            body["context_uri"] = contextURI
            if let trackURI { body["offset"] = ["uri": trackURI] }
        } else if let uris, !uris.isEmpty {
            body["uris"] = Array(uris.prefix(50))
        } else if let trackURI {
            body["uris"] = [trackURI]
        }
        let expectedURI = trackURI ?? uris?.first
        await run(mutation: .play(expectedURI: expectedURI)) {
            // Honor #16 / map #1: a 404 / no active device never starts librespot.
            try await SpotifyClient.shared.command("PUT", "me/player/play", body: body.isEmpty ? nil : body)
        }
    }

    func progress(at date: Date = .now) -> Int {
        progressState.progress(at: date)
    }

    private func publishNowPlaying() {
        nowPlaying.sync(
            isLocalEngineRunning: localEngine.isRunning,
            activeDeviceID: state?.device?.id ?? lastConfirmedDeviceID,
            localDeviceID: localDeviceID,
            track: state?.item,
            progressMs: progressState.progress(at: Date()),
            isPlaying: progressState.isPlaying
        )
    }

    private func updateLastConfirmedDevice(from refreshedState: PlaybackState?) {
        lastConfirmedDeviceID = PlaybackActiveDevice.confirmedID(from: refreshedState)
    }

    private func localConnectDevice(from devices: [Device]) -> Device? {
        devices.first { device in
            device.name == LibrespotEngine.deviceName && !(device.id ?? "").isEmpty
        }
    }

    private func forgetLocalPlaybackSession() {
        if lastConfirmedDeviceID == localDeviceID {
            lastConfirmedDeviceID = nil
        }
        localDeviceID = nil
    }

    /// After a crash relaunch the Connect device id may change. Recapture it
    /// and retarget playback so the session continues. First start leaves
    /// capture to `ensureLocalDevice`.
    private func handleEngineBecameRunning() async {
        let previousID = localDeviceID
        guard previousID != nil else { return }
        localDeviceID = nil
        publishNowPlaying()
        let attempts = localEngine.needsAuthorization ? 60 : 10
        for attempt in 0..<attempts {
            await loadDevices()
            if let device = localConnectDevice(from: devices) {
                localDeviceID = device.id
                if device.id != previousID {
                    await transferPlayback(to: device)
                }
                publishNowPlaying()
                reconcilePolling()
                return
            }
            if !localEngine.isRunning { return }
            try? await Task.sleep(for: .seconds(attempt == 0 ? 1.5 : 1))
        }
    }

    private func nextPollIntervalSeconds() -> Int? {
        PlaybackPollingPolicy.intervalSeconds(
            isPlaying: state?.isPlaying ?? false,
            isSceneActive: isSceneActive,
            isLocalDeviceActive: isLocalDeviceActive
        )
    }

    private func reconcilePolling() {
        if nextPollIntervalSeconds() == nil {
            stopPolling()
        } else if pollTask == nil {
            startPolling()
        }
    }

    private func run(
        mutation: PlaybackMutation? = nil,
        refreshAfter: Bool = true,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            lastError = nil
            if let mutation {
                await synchronizePlaybackAndQueue(after: mutation)
            } else if refreshAfter {
                try? await Task.sleep(for: PlaybackQueueSync.propagationDelay)
                await refresh()
            }
        } catch {
            lastError = friendlyMessage(for: error)
        }
    }

    private func synchronizePlaybackAndQueue(after mutation: PlaybackMutation) async {
        playbackSyncTask?.cancel()
        let task = Task { await self.runSynchronization(after: mutation) }
        playbackSyncTask = task
        await task.value
    }

    private func runSynchronization(after mutation: PlaybackMutation) async {
        try? await Task.sleep(for: PlaybackQueueSync.propagationDelay)
        guard !Task.isCancelled else { return }

        for attempt in 1...PlaybackQueueSync.maxAttempts {
            await refresh()
            await loadQueue(force: true)
            guard !Task.isCancelled else { return }

            let snapshot = PlaybackQueueSnapshot(
                playback: state,
                currentlyPlaying: queueState.currentlyPlaying,
                upcoming: queueState.upcoming
            )
            if !PlaybackQueueSync.isStale(snapshot, after: mutation) {
                return
            }
            if attempt < PlaybackQueueSync.maxAttempts {
                try? await Task.sleep(for: PlaybackQueueSync.retryDelay)
                guard !Task.isCancelled else { return }
            }
        }
    }

    private func performQueueFetch(generation: Int) async {
        do {
            let response: QueueResponse = try await SpotifyClient.shared.get("me/player/queue")
            var nextState = queueState
            nextState.applySuccess(generation: generation, response: response)
            queueState = nextState
        } catch is CancellationError {
            var nextState = queueState
            nextState.cancel(generation: generation)
            queueState = nextState
        } catch {
            var nextState = queueState
            nextState.applyFailure(generation: generation, message: friendlyMessage(for: error))
            queueState = nextState
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        if let apiError = error as? SpotifyAPIError,
           case .http(let status, _) = apiError {
            switch status {
            case 401: return "Your Spotify session expired. Log out and sign in again."
            case 403: return "Spotify rejected playback control. Check that your account is Premium and that a device is active."
            case 404: return "No active Spotify device. Open Spotify on a device and try again."
            default: break
            }
        }
        if (error as? URLError) != nil {
            return "No connection to Spotify. Check your internet connection."
        }
        return error.localizedDescription
    }
}
