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
    /// only while the last confirmed active Connect **device id** is the local
    /// librespot device. Same 5 s / 30 s playback poll; not a second Now Playing loop.
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
    /// Consent / missing-binary sheet for opt-in local playback.
    var localPlaybackSheetPresented = false
    /// Optimistic volume so keyboard +/- update the slider without waiting for poll.
    var volumePercent: Int = 50

    let localEngine = LibrespotEngine()
    @ObservationIgnored
    let nowPlaying: NowPlayingBridge
    @ObservationIgnored
    private let consentStore: LocalPlaybackConsentStore
    @ObservationIgnored
    private let applicationSupportURL: URL?

    private var pollTask: Task<Void, Never>?
    private var pollGeneration = 0
    private var localDeviceDiscoveryTask: Task<Device?, Never>?
    /// Dead session: stop scene network work without looking still logged-in-and-retrying.
    private var haltSceneNetwork = false
    private var progressState = PlaybackProgressState()
    private var seekRequestID = 0
    private var queueState = QueueRefreshState()
    private var queueLoadTask: Task<Void, Never>?
    private var playbackSyncTask: Task<Void, Never>?
    /// Serial playback command queue. Identical pending items coalesce; drain
    /// runs one mutation at a time. This is the only command queue.
    private var playbackWorkItems: [PlaybackWorkItem] = []
    private var isDrainingPlaybackWork = false
    private var inFlightPlaybackItem: PlaybackWorkItem?
    private var inFlightPlaybackTask: Task<Void, Never>?
    private var playbackCommandEpoch = 0
    private var remoteApplyGeneration = 0
    private var pendingPollConfirmation: PlaybackMutation?
    private var pendingPollConfirmationDeadline: Date?
    /// Survives later play/pause mutations. Polls of any URI already skipped
    /// past — including an older URI after two skips — must not revert the bar.
    private var skipPollGuard = PlaybackQueueSync.SkipPollGuard()
    /// Last distinct track the bar already showed. One slot, not a history stack.
    private var lastBarTrack: Track?
    private(set) var isPlaybackCommandInFlight = false

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
    private(set) var currentSpotifyUserID: String?
    private(set) var hasLocalPlaybackConsent = false

    init(
        nowPlaying: NowPlayingBridge? = nil,
        consentStore: LocalPlaybackConsentStore = LocalPlaybackConsentStore(),
        applicationSupportURL: URL? = nil
    ) {
        self.nowPlaying = nowPlaying ?? NowPlayingBridge()
        self.consentStore = consentStore
        self.applicationSupportURL = applicationSupportURL
        self.currentSpotifyUserID = consentStore.lastSignedInUserID
        self.localEngine.accountUserID = consentStore.lastSignedInUserID
        if let userID = consentStore.lastSignedInUserID {
            self.hasLocalPlaybackConsent = consentStore.hasConsent(for: userID)
        }
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
        localEngine.onProcessExited = { [weak self] in
            self?.forgetLocalPlaybackSession()
            self?.publishNowPlaying()
            self?.reconcilePolling()
        }
    }

    var currentTrackIdentifier: String? {
        state?.item?.id ?? state?.item?.uri
    }

    var isPlaying: Bool {
        progressState.isPlaying
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

    var localPlaybackMenuTitle: String {
        LocalPlaybackMenuCopy.itemTitle(
            hasConsent: hasLocalPlaybackConsent,
            isStarting: localEngine.status == .starting
        )
    }

    /// Binds librespot cache and consent to this Spotify account. A different
    /// user id is treated as an account switch: the previous cache is wiped.
    func bindSpotifyAccount(_ userID: String) {
        guard let id = LocalPlaybackConsentStore.normalizedUserID(userID) else { return }
        if let previous = currentSpotifyUserID ?? consentStore.lastSignedInUserID, previous != id {
            stopLocalPlayback()
            wipeLibrespotCredentials(for: previous)
            localPlaybackSheetPresented = false
        } else {
            // Drop the unscoped pre-#16 cache so it cannot be reused by accident.
            wipeLibrespotCredentials(for: nil)
        }
        currentSpotifyUserID = id
        localEngine.accountUserID = id
        consentStore.rememberSignedInUser(id)
        hasLocalPlaybackConsent = consentStore.hasConsent(for: id)
    }

    func grantLocalPlaybackConsent() {
        guard let currentSpotifyUserID else { return }
        consentStore.grantConsent(for: currentSpotifyUserID)
        hasLocalPlaybackConsent = true
    }

    @discardableResult
    func resolveSpotifyAccount() async -> Bool {
        if currentSpotifyUserID != nil { return true }
        guard let profile: UserProfile = try? await SpotifyClient.shared.get("me") else {
            lastError = LibrespotAccountCacheError.missingSpotifyAccount.localizedDescription
            return false
        }
        bindSpotifyAccount(profile.id)
        return currentSpotifyUserID != nil
    }

    func setSceneActive(_ active: Bool) {
        let changed = isSceneActive != active
        isSceneActive = active
        guard changed else { return }
        if active {
            // A background 30 s poll may be mid-sleep; restart so the
            // foreground 5 s cadence applies immediately.
            stopPolling()
        } else {
            cancelLocalDeviceDiscovery()
        }
        reconcilePolling()
    }

    func startPolling() {
        guard !haltSceneNetwork else { return }
        guard pollTask == nil else { return }
        guard nextPollIntervalSeconds() != nil else { return }
        pollGeneration += 1
        let generation = pollGeneration
        pollTask = Task {
            while !Task.isCancelled && !haltSceneNetwork {
                await refresh()
                guard !haltSceneNetwork, let seconds = nextPollIntervalSeconds() else { break }
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
        if haltSceneNetwork { return }
        let generation = remoteApplyGeneration
        do {
            let refreshedState: PlaybackState? = try await SpotifyClient.shared.getOptional("me/player")
            guard generation == remoteApplyGeneration else { return }
            let snapshot = PlaybackQueueSnapshot(
                playback: refreshedState,
                currentlyPlaying: queueState.currentlyPlaying,
                upcoming: queueState.upcoming
            )
            if !PlaybackQueueSync.shouldApplyPlaybackPoll(
                snapshot,
                pendingMutation: pendingPollConfirmation,
                skipGuard: skipPollGuard,
                now: Date(),
                deadline: pendingPollConfirmationDeadline
            ) {
                return
            }
            pendingPollConfirmation = nil
            pendingPollConfirmationDeadline = nil
            skipPollGuard.reset()
            if state?.item?.uri != refreshedState?.item?.uri {
                rememberLastBarTrack(leaving: state?.item)
            }
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
            queueState.alignToPlayingURI(refreshedState?.item?.uri)
            lastError = nil
            publishNowPlaying()
        } catch is CancellationError {
            return
        } catch {
            if isDeadSession(error) {
                haltForDeadSession()
                return
            }
            lastError = friendlyMessage(for: error)
        }
    }

    func loadDevices() async {
        if haltSceneNetwork { return }
        do {
            let response: DevicesResponse? = try await SpotifyClient.shared.getOptional("me/player/devices")
            devices = response?.devices ?? []
        } catch is CancellationError {
            return
        } catch {
            if isDeadSession(error) {
                haltForDeadSession()
            }
        }
    }

    func play() async {
        let epoch = beginPlaybackCommand()
        let snapshot = capturePlaybackUI()
        applyOptimisticPlaying(true)
        await run(
            coalesceKey: .play,
            mutation: .setPlaying(true),
            confirmViaExistingPoll: true,
            revertOptimistic: { self.restorePlaybackUI(snapshot, ifEpoch: epoch) }
        ) {
            try await SpotifyClient.shared.command("PUT", "me/player/play")
        }
    }

    func pause() async {
        let epoch = beginPlaybackCommand()
        let snapshot = capturePlaybackUI()
        applyOptimisticPlaying(false)
        await run(
            coalesceKey: .pause,
            mutation: .setPlaying(false),
            confirmViaExistingPoll: true,
            revertOptimistic: { self.restorePlaybackUI(snapshot, ifEpoch: epoch) }
        ) {
            try await SpotifyClient.shared.command("PUT", "me/player/pause")
        }
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
        await submitPlaybackWork(coalesceKey: .next) {
            let snapshot = self.capturePlaybackUI()
            let epoch = self.beginPlaybackCommand()
            let mutation = PlaybackMutation.skipForward(
                previousURI: self.state?.item?.uri,
                expectedNextURI: self.queue.first?.uri
            )
            self.applyOptimisticSkipForward()
            self.armSkipPollGuard(mutation)
            await self.performSerializedCommand(
                mutation: mutation,
                confirmViaExistingPoll: true,
                revertOptimistic: { self.restorePlaybackUI(snapshot, ifEpoch: epoch) }
            ) {
                try await SpotifyClient.shared.command("POST", "me/player/next")
            }
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
        // Previous always POSTs to Spotify (#12). The bar confirms from that
        // HTTP in the general case: restore the last track this bar already
        // showed, or restart the current item at 0. No GET /me/player, no stack.
        await submitPlaybackWork(coalesceKey: .previous) {
            let snapshot = self.capturePlaybackUI()
            let epoch = self.beginPlaybackCommand()
            let mutation = PlaybackMutation.skipBack(previousURI: self.state?.item?.uri)
            let restoredTrack = self.applyOptimisticPrevious()
            self.armSkipPollGuard(mutation)
            await self.performSerializedCommand(
                mutation: mutation,
                confirmViaExistingPoll: restoredTrack,
                revertOptimistic: { self.restorePlaybackUI(snapshot, ifEpoch: epoch) }
            ) {
                try await SpotifyClient.shared.command("POST", "me/player/previous")
            }
        }
    }

    func setShuffle(_ enabled: Bool) async {
        let epoch = beginPlaybackCommand()
        let snapshot = capturePlaybackUI()
        applyOptimisticShuffle(enabled)
        await run(
            coalesceKey: .shuffle(enabled: enabled),
            mutation: .shuffle(enabled: enabled),
            confirmViaExistingPoll: true,
            revertOptimistic: { self.restorePlaybackUI(snapshot, ifEpoch: epoch) }
        ) {
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

        let snapshot = capturePlaybackUI()
        let epoch = beginPlaybackCommand()
        let now = Date()
        let isPlaying = progressState.isPlaying
        progressState.applyLocalSeek(
            trackID: expectedTrackID,
            durationMs: durationMs,
            targetMs: positionMs,
            isPlaying: isPlaying,
            at: now
        )
        publishNowPlaying()

        seekRequestID += 1
        let requestID = seekRequestID
        let normalizedPosition = progressState.progress(at: now)
        guard expectedTrackID == currentTrackIdentifier else {
            restorePlaybackUI(snapshot)
            return
        }

        await run(
            coalesceKey: .seek(positionMs: normalizedPosition, expectedTrackID: expectedTrackID),
            revertOptimistic: {
                guard requestID == self.seekRequestID else { return }
                self.restorePlaybackUI(snapshot, ifEpoch: epoch)
            }
        ) {
            try await SpotifyClient.shared.command(
                "PUT",
                "me/player/seek",
                query: ["position_ms": String(normalizedPosition)]
            )
            guard requestID == self.seekRequestID else { return }
        }
    }

    func setVolume(_ percent: Int) async {
        let next = min(100, max(0, percent))
        let previous = volumePercent
        let epoch = beginPlaybackCommand()
        volumePercent = next
        await run(
            coalesceKey: .volume(percent: next),
            revertOptimistic: {
                guard epoch == self.playbackCommandEpoch, self.volumePercent == next else { return }
                self.volumePercent = previous
            }
        ) {
            try await SpotifyClient.shared.command(
                "PUT", "me/player/volume",
                query: ["volume_percent": String(next)]
            )
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

    /// Starts the local librespot engine only after this Spotify account has
    /// consented. Without consent, or if the binary is missing, the sheet opens
    /// instead of launching a process. This is the only path that starts
    /// librespot; 404 / no-device / locator success never call it.
    func playOnThisMac() async {
        guard await resolveSpotifyAccount() else { return }
        let mayStart = LocalPlaybackStartPolicy.shouldLaunchLibrespot(
            for: .explicitOptIn,
            hasAccountConsent: hasLocalPlaybackConsent
        )
        guard mayStart else {
            localPlaybackSheetPresented = true
            return
        }
        guard LibrespotLocator.isInstalled else {
            localPlaybackSheetPresented = true
            return
        }
        guard let device = await ensureLocalDevice() else { return }
        await transferPlayback(to: device)
        reconcilePolling()
    }

    /// Called only from `playOnThisMac` after the inline opt-in gate.
    /// Locator success does not launch.
    private func ensureLocalDevice() async -> Device? {
        cancelLocalDeviceDiscovery()
        let task = Task<Device?, Never> { await self.performLocalDeviceDiscovery() }
        localDeviceDiscoveryTask = task
        let device = await task.value
        if localDeviceDiscoveryTask == task {
            localDeviceDiscoveryTask = nil
        }
        return device
    }

    private func performLocalDeviceDiscovery() async -> Device? {
        if haltSceneNetwork || Task.isCancelled { return nil }
        await localEngine.start()
        guard localEngine.isRunning else {
            if Task.isCancelled || haltSceneNetwork { return nil }
            if localEngine.isNotInstalled {
                // Missing binary is a setup task, not an error: show the
                // consent/install sheet instead of the red banner.
                localPlaybackSheetPresented = true
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
            if Task.isCancelled || haltSceneNetwork { return nil }
            await loadDevices()
            if let device = localConnectDevice(from: devices) {
                localDeviceID = device.id
                return device
            }
            if !localEngine.isRunning { break }
            try? await Task.sleep(for: .seconds(attempt == 0 ? 1.5 : 1))
        }
        if Task.isCancelled || haltSceneNetwork { return nil }
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

    /// Stops scene-owned work immediately. Does not wait for in-flight tasks
    /// to drain. Playback mutations belong to the command that started them.
    func handleSignOut() {
        haltSceneNetwork = false
        cancelLocalDeviceDiscovery()
        queueLoadTask?.cancel()
        queueLoadTask = nil
        playbackSyncTask?.cancel()
        playbackSyncTask = nil
        stopPolling()
        clearPollConfirmation()
        skipPollGuard.reset()
        lastBarTrack = nil
        clearPlaybackWorkQueue()
        stopLocalPlayback()
        wipeLibrespotCredentials(for: currentSpotifyUserID ?? consentStore.lastSignedInUserID)
        consentStore.clearLastSignedInUser()
        currentSpotifyUserID = nil
        localEngine.accountUserID = nil
        hasLocalPlaybackConsent = false
        localPlaybackSheetPresented = false
        state = nil
        lastConfirmedDeviceID = nil
        lastError = nil
        nowPlaying.clear()
    }

    /// Dead OAuth session: cancel poll and discovery and move on. Does not
    /// sign the user out — the #13 banner owns logout.
    func haltForDeadSession() {
        haltSceneNetwork = true
        cancelLocalDeviceDiscovery()
        stopPolling()
    }

    private func cancelLocalDeviceDiscovery() {
        localDeviceDiscoveryTask?.cancel()
        localDeviceDiscoveryTask = nil
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
        // 404 / no active device must not start librespot (issue #16, PERFORMANCE.md).
        await run(mutation: .play(expectedURI: expectedURI)) {
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

    private func nextPollIntervalSeconds() -> Int? {
        PlaybackPollingPolicy.intervalSeconds(
            isPlaying: isPlaying,
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
        coalesceKey: PlaybackCommand? = nil,
        mutation: PlaybackMutation? = nil,
        confirmViaExistingPoll: Bool = false,
        revertOptimistic: (() -> Void)? = nil,
        operation: @escaping () async throws -> Void
    ) async {
        await submitPlaybackWork(coalesceKey: coalesceKey) {
            await self.performSerializedCommand(
                mutation: mutation,
                confirmViaExistingPoll: confirmViaExistingPoll,
                revertOptimistic: revertOptimistic,
                operation: operation
            )
        }
    }

    private func submitPlaybackWork(
        coalesceKey: PlaybackCommand?,
        work: @escaping () async -> Void
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if let coalesceKey {
                if let last = playbackWorkItems.last, last.coalesceKey == coalesceKey {
                    last.continuations.append(continuation)
                    return
                }
                if playbackWorkItems.isEmpty,
                   let inFlight = inFlightPlaybackItem,
                   inFlight.coalesceKey == coalesceKey {
                    inFlight.continuations.append(continuation)
                    return
                }
                if let last = playbackWorkItems.last,
                   let lastKey = last.coalesceKey,
                   coalesceKey.supersedes(lastKey) {
                    last.coalesceKey = coalesceKey
                    last.work = work
                    last.continuations.append(continuation)
                    if let inFlightKey = inFlightPlaybackItem?.coalesceKey,
                       coalesceKey.supersedes(inFlightKey) {
                        inFlightPlaybackTask?.cancel()
                    }
                    return
                }
                if let inFlightKey = inFlightPlaybackItem?.coalesceKey,
                   coalesceKey.supersedes(inFlightKey) {
                    inFlightPlaybackTask?.cancel()
                }
            }
            playbackWorkItems.append(
                PlaybackWorkItem(
                    coalesceKey: coalesceKey,
                    continuations: [continuation],
                    work: work
                )
            )
            Task { await self.drainPlaybackWork() }
        }
    }

    /// Sign-out: cancel the in-flight command and drop queued ones. Their
    /// callers resume immediately; nothing else is sent to Spotify.
    private func clearPlaybackWorkQueue() {
        inFlightPlaybackTask?.cancel()
        let pending = playbackWorkItems
        playbackWorkItems.removeAll()
        for item in pending {
            for continuation in item.continuations {
                continuation.resume()
            }
        }
    }

    private func drainPlaybackWork() async {
        guard !isDrainingPlaybackWork else { return }
        isDrainingPlaybackWork = true
        isPlaybackCommandInFlight = true
        defer {
            isDrainingPlaybackWork = false
            isPlaybackCommandInFlight = false
            inFlightPlaybackItem = nil
            inFlightPlaybackTask = nil
        }
        while !playbackWorkItems.isEmpty {
            let item = playbackWorkItems.removeFirst()
            inFlightPlaybackItem = item
            let task = Task { await item.work() }
            inFlightPlaybackTask = task
            await task.value
            inFlightPlaybackTask = nil
            inFlightPlaybackItem = nil
            for continuation in item.continuations {
                continuation.resume()
            }
        }
    }

    private func performSerializedCommand(
        mutation: PlaybackMutation?,
        confirmViaExistingPoll: Bool,
        revertOptimistic: (() -> Void)?,
        operation: () async throws -> Void
    ) async {
        invalidateInFlightRemoteReads()
        // Drop the previous command's poll mutation so a leftover skipForward
        // filter cannot swallow Previous's catch-up poll. The skip URI guard
        // is armed by next/previous themselves and lives on the UI snapshot.
        clearPollConfirmation()
        if confirmViaExistingPoll, let mutation {
            pendingPollConfirmation = mutation
            let interval = nextPollIntervalSeconds()
                ?? PlaybackPollingPolicy.foregroundIdleIntervalSeconds
            pendingPollConfirmationDeadline = PlaybackQueueSync.confirmationDeadline(
                now: Date(),
                pollIntervalSeconds: interval
            )
        }
        var operationCompleted = false
        do {
            try Task.checkCancellation()
            try await operation()
            operationCompleted = true
            lastError = nil
            invalidateInFlightRemoteReads()
            // A superseded POST that already got HTTP 204 must not confirm the
            // mutation, but the server did apply it: keep the optimistic UI and
            // let the next command / poll settle the truth.
            try Task.checkCancellation()
            if let mutation {
                armSkipPollGuard(mutation)
            }
            if let mutation, mutation.requiresPlaybackAndQueueSync, !confirmViaExistingPoll {
                await synchronizePlaybackAndQueue(after: mutation)
            }
        } catch is CancellationError {
            invalidateInFlightRemoteReads()
            if !operationCompleted {
                clearPollConfirmation()
                revertOptimistic?()
                publishNowPlaying()
            }
        } catch {
            invalidateInFlightRemoteReads()
            clearPollConfirmation()
            revertOptimistic?()
            publishNowPlaying()
            if isDeadSession(error) {
                haltForDeadSession()
                return
            }
            lastError = friendlyMessage(for: error)
        }
    }

    private func invalidateInFlightRemoteReads() {
        remoteApplyGeneration += 1
    }

    private func clearPollConfirmation() {
        pendingPollConfirmation = nil
        pendingPollConfirmationDeadline = nil
    }

    private func armSkipPollGuard(_ mutation: PlaybackMutation) {
        skipPollGuard.record(
            leaving: mutation.playingURIToIgnoreAfterSuccess,
            nowPlaying: state?.item?.uri,
            at: Date()
        )
    }

    private func beginPlaybackCommand() -> Int {
        playbackCommandEpoch += 1
        return playbackCommandEpoch
    }

    private struct PlaybackUISnapshot {
        var state: PlaybackState?
        var progressState: PlaybackProgressState
        var volumePercent: Int
        var queueState: QueueRefreshState
        var skipPollGuard: PlaybackQueueSync.SkipPollGuard
        var lastBarTrack: Track?
        var pendingPollConfirmation: PlaybackMutation?
        var pendingPollConfirmationDeadline: Date?
    }

    private func capturePlaybackUI() -> PlaybackUISnapshot {
        PlaybackUISnapshot(
            state: state,
            progressState: progressState,
            volumePercent: volumePercent,
            queueState: queueState,
            skipPollGuard: skipPollGuard,
            lastBarTrack: lastBarTrack,
            pendingPollConfirmation: pendingPollConfirmation,
            pendingPollConfirmationDeadline: pendingPollConfirmationDeadline
        )
    }

    private func restorePlaybackUI(_ snapshot: PlaybackUISnapshot, ifEpoch epoch: Int) {
        guard epoch == playbackCommandEpoch else { return }
        restorePlaybackUI(snapshot)
    }

    private func restorePlaybackUI(_ snapshot: PlaybackUISnapshot) {
        state = snapshot.state
        progressState = snapshot.progressState
        volumePercent = snapshot.volumePercent
        queueState = snapshot.queueState
        skipPollGuard = snapshot.skipPollGuard
        lastBarTrack = snapshot.lastBarTrack
        pendingPollConfirmation = snapshot.pendingPollConfirmation
        pendingPollConfirmationDeadline = snapshot.pendingPollConfirmationDeadline
    }

    private func applyOptimisticPlaying(_ playing: Bool) {
        progressState.applyPlaybackStatus(isPlaying: playing, at: Date())
        if let current = state {
            state = current.applying(isPlaying: playing)
        }
        publishNowPlaying()
    }

    private func applyOptimisticShuffle(_ enabled: Bool) {
        if let current = state {
            state = current.applying(shuffleState: enabled)
        }
        publishNowPlaying()
    }

    private func rememberLastBarTrack(leaving: Track?) {
        guard let leaving else { return }
        lastBarTrack = leaving
    }

    private func applyOptimisticSkipForward() {
        guard let upcoming = queue.first else { return }
        rememberLastBarTrack(leaving: state?.item)
        if let current = state {
            state = current.applying(item: upcoming, replaceItem: true, progressMs: 0)
        }
        progressState.applyRemoteState(
            trackID: upcoming.id ?? upcoming.uri,
            durationMs: upcoming.durationMs,
            progressMs: 0,
            isPlaying: progressState.isPlaying,
            receivedAt: Date()
        )
        queueState.applyOptimisticSkipForward()
        queueLoadTask?.cancel()
        publishNowPlaying()
    }

    /// Returns true when the bar restored a track it already showed.
    private func applyOptimisticPrevious() -> Bool {
        let current = state?.item
        if PlaybackQueueSync.shouldRestoreLastDisplayedTrack(
            lastDisplayedURI: lastBarTrack?.uri,
            currentURI: current?.uri
        ), let previous = lastBarTrack {
            lastBarTrack = nil
            if let state {
                self.state = state.applying(item: previous, replaceItem: true, progressMs: 0)
            }
            progressState.applyRemoteState(
                trackID: previous.id ?? previous.uri,
                durationMs: previous.durationMs,
                progressMs: 0,
                isPlaying: progressState.isPlaying,
                receivedAt: Date()
            )
            queueState.applyOptimisticSkipBack(returning: previous, leaving: current)
            queueLoadTask?.cancel()
            publishNowPlaying()
            return true
        }
        applyOptimisticPreviousRestart()
        return false
    }

    /// General case (idle, play, pause): confirm Previous on the current item
    /// at 0. POST is the confirmation; the existing poll may catch up a
    /// different URI later without the command waiting on it.
    private func applyOptimisticPreviousRestart() {
        guard let current = state?.item else { return }
        if let state {
            self.state = state.applying(progressMs: 0)
        }
        progressState.applyRemoteState(
            trackID: current.id ?? current.uri,
            durationMs: current.durationMs,
            progressMs: 0,
            isPlaying: progressState.isPlaying,
            receivedAt: Date()
        )
        publishNowPlaying()
    }

    private final class PlaybackWorkItem {
        var coalesceKey: PlaybackCommand?
        var continuations: [CheckedContinuation<Void, Never>]
        var work: () async -> Void

        init(
            coalesceKey: PlaybackCommand?,
            continuations: [CheckedContinuation<Void, Never>],
            work: @escaping () async -> Void
        ) {
            self.coalesceKey = coalesceKey
            self.continuations = continuations
            self.work = work
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
            nextState.alignToPlayingURI(state?.item?.uri)
            queueState = nextState
        } catch is CancellationError {
            var nextState = queueState
            nextState.cancel(generation: generation)
            queueState = nextState
        } catch {
            if isDeadSession(error) {
                haltForDeadSession()
            }
            var nextState = queueState
            nextState.applyFailure(generation: generation, message: friendlyMessage(for: error))
            queueState = nextState
        }
    }

    private func isDeadSession(_ error: Error) -> Bool {
        (error as? SpotifyAPIError)?.isSessionExpired == true
    }

    private func friendlyMessage(for error: Error) -> String {
        if let apiError = error as? SpotifyAPIError {
            if apiError.isSessionExpired {
                return SpotifyAPIError.sessionExpiredMessage
            }
            if case .http(let status, _) = apiError {
                switch status {
                case 401: return SpotifyAPIError.sessionExpiredMessage
                case 403: return "Spotify rechazó el control de reproducción. Necesitas una cuenta Premium."
                case 404: return "No hay ningún dispositivo activo. Abre Spotify en un dispositivo o reproduce en esta Mac."
                case 429: return SpotifyAPIError.rateLimitedMessage
                default: break
                }
            }
        }
        if error is URLError {
            return "Sin conexión a internet. Revisa tu red e inténtalo de nuevo."
        }
        if error is LocalizedError || error is AuthError {
            return error.localizedDescription
        }
        return "No se pudo cargar. Inténtalo de nuevo."
    }

    private func wipeLibrespotCredentials(for userID: String?) {
        let applicationSupport: URL
        if let applicationSupportURL {
            applicationSupport = applicationSupportURL
        } else if let resolved = try? LibrespotAccountCache.defaultApplicationSupport() {
            applicationSupport = resolved
        } else {
            return
        }
        LibrespotAccountCache.wipeCredentials(
            for: userID,
            applicationSupport: applicationSupport
        )
    }
}

enum PlaybackCommand: Equatable {
    case play
    case pause
    case next
    case previous
    case seek(positionMs: Int, expectedTrackID: String?)
    case volume(percent: Int)
    case shuffle(enabled: Bool)

    /// A newer command replaces an in-flight POST instead of waiting for it.
    func supersedes(_ inFlight: PlaybackCommand) -> Bool {
        switch (inFlight, self) {
        case (.seek, .seek), (.volume, .volume), (.shuffle, .shuffle):
            return true
        case (.play, .pause), (.pause, .play):
            return true
        case (.next, .previous), (.previous, .next):
            return true
        default:
            return false
        }
    }
}
