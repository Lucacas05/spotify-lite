import Foundation
import Observation

/// Wraps a local-engine failure so it survives `run`'s error handling with the
/// specific cause instead of the generic "no active device" message.
struct LocalPlaybackError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

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
    /// Survives a later play/pause pending mutation. Polls that still report
    /// this URI must not undo a skip.
    private var ignoreStalePlayingURI: String?
    private(set) var isPlaybackCommandInFlight = false

    var queue: [Track] { queueState.upcoming }
    var queueRows: [QueueRowItem] { queueState.rows }
    var queueIsLoading: Bool { queueState.isLoading }
    var queueError: String? { queueState.lastError }
    var queuePresentation: QueuePresentation { queueState.presentation }

    private var isSceneActive = false
    private(set) var lastConfirmedDeviceName: String?

    init(nowPlaying: NowPlayingBridge? = nil) {
        self.nowPlaying = nowPlaying ?? NowPlayingBridge()
        self.nowPlaying.onCommand = { [weak self] command in
            Task { await self?.handleNowPlayingCommand(command) }
        }
        // Surface asynchronous engine deaths (crash-restart budget exhausted)
        // as a banner; the app keeps working in remote-control mode.
        localEngine.onUnrecoverableFailure = { [weak self] message in
            self?.lastError = message
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
        lastConfirmedDeviceName == LibrespotEngine.deviceName
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
                ignoringPlayingURI: ignoreStalePlayingURI,
                now: Date(),
                deadline: pendingPollConfirmationDeadline
            ) {
                return
            }
            pendingPollConfirmation = nil
            pendingPollConfirmationDeadline = nil
            ignoreStalePlayingURI = nil
            state = refreshedState
            updateLastConfirmedDeviceName(from: refreshedState)
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
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadDevices() async {
        let response: DevicesResponse? = try? await SpotifyClient.shared.getOptional("me/player/devices")
        devices = response?.devices ?? []
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
            self.armSkipPollGuard(mutation)
            self.applyOptimisticSkipForward()
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
        // Previous delegates to Spotify. There is no local history stack (#12).
        // Confirmation is the mutation HTTP result, not a later GET /me/player.
        await submitPlaybackWork(coalesceKey: .previous) {
            let snapshot = self.capturePlaybackUI()
            let epoch = self.beginPlaybackCommand()
            let mutation = PlaybackMutation.skipBack(previousURI: self.state?.item?.uri)
            self.armSkipPollGuard(mutation)
            await self.performSerializedCommand(
                mutation: mutation,
                confirmViaExistingPoll: false,
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
            if let device = devices.first(where: { $0.name == LibrespotEngine.deviceName }) {
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
        clearPollConfirmation()
        ignoreStalePlayingURI = nil
        state = nil
        lastConfirmedDeviceName = nil
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
            do {
                try await SpotifyClient.shared.command("PUT", "me/player/play", body: body.isEmpty ? nil : body)
            } catch let error as SpotifyAPIError where error.isNoActiveDevice {
                // No active Connect device anywhere: fall back to the local
                // librespot engine and target it explicitly.
                guard let device = await ensureLocalDevice(), let deviceID = device.id else {
                    // The setup sheet is already telling the user what to do;
                    // a red banner on top would be noise.
                    if localSetupNeeded { return }
                    // ensureLocalDevice already set lastError to the real cause;
                    // rethrowing the 404 would mask it behind the generic message.
                    throw LocalPlaybackError(message: lastError ?? error.localizedDescription)
                }
                try await SpotifyClient.shared.command(
                    "PUT", "me/player/play",
                    query: ["device_id": deviceID],
                    body: body.isEmpty ? nil : body)
            }
        }
    }

    func progress(at date: Date = .now) -> Int {
        progressState.progress(at: date)
    }

    private func publishNowPlaying() {
        nowPlaying.sync(
            isLocalEngineRunning: localEngine.isRunning,
            activeDeviceName: state?.device?.name ?? lastConfirmedDeviceName,
            track: state?.item,
            progressMs: progressState.progress(at: Date()),
            isPlaying: progressState.isPlaying
        )
    }

    private func updateLastConfirmedDeviceName(from refreshedState: PlaybackState?) {
        if let name = refreshedState?.device?.name {
            lastConfirmedDeviceName = name
        } else if refreshedState != nil {
            lastConfirmedDeviceName = nil
        } else if !localEngine.isRunning {
            lastConfirmedDeviceName = nil
        }
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
        do {
            try Task.checkCancellation()
            try await operation()
            // A superseded POST that already got HTTP 204 must not confirm.
            try Task.checkCancellation()
            lastError = nil
            invalidateInFlightRemoteReads()
            if let mutation {
                armSkipPollGuard(mutation)
            }
            if let mutation, mutation.requiresPlaybackAndQueueSync, !confirmViaExistingPoll {
                await synchronizePlaybackAndQueue(after: mutation)
            }
        } catch is CancellationError {
            invalidateInFlightRemoteReads()
            revertOptimistic?()
            publishNowPlaying()
        } catch {
            invalidateInFlightRemoteReads()
            revertOptimistic?()
            publishNowPlaying()
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
        if let uri = mutation.playingURIToIgnoreAfterSuccess {
            ignoreStalePlayingURI = uri
        }
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
        var ignoreStalePlayingURI: String?
        var pendingPollConfirmation: PlaybackMutation?
        var pendingPollConfirmationDeadline: Date?
    }

    private func capturePlaybackUI() -> PlaybackUISnapshot {
        PlaybackUISnapshot(
            state: state,
            progressState: progressState,
            volumePercent: volumePercent,
            queueState: queueState,
            ignoreStalePlayingURI: ignoreStalePlayingURI,
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
        ignoreStalePlayingURI = snapshot.ignoreStalePlayingURI
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

    private func applyOptimisticSkipForward() {
        guard let upcoming = queue.first else { return }
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
