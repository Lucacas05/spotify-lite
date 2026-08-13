import Foundation
import Observation

/// Wraps a local-engine failure so it survives `run`'s error handling with the
/// specific cause instead of the generic "no active device" message.
struct LocalPlaybackError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
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
    private(set) var queue: [Track] = []
    private(set) var queueIsLoading = false
    var lastError: String?

    let localEngine = LibrespotEngine()

    private var pollTask: Task<Void, Never>?
    private var progressState = PlaybackProgressState()
    private var seekRequestID = 0

    var currentTrackIdentifier: String? {
        state?.item?.id ?? state?.item?.uri
    }

    var isShuffling: Bool {
        state?.shuffleState ?? false
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        do {
            let refreshedState: PlaybackState? = try await SpotifyClient.shared.getOptional("me/player")
            state = refreshedState
            let now = Date()
            progressState.applyRemoteState(
                trackID: refreshedState?.item?.id ?? refreshedState?.item?.uri,
                durationMs: refreshedState?.item?.durationMs,
                progressMs: refreshedState?.progressMs,
                isPlaying: refreshedState?.isPlaying ?? false,
                receivedAt: now
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadDevices() async {
        let response: DevicesResponse? = try? await SpotifyClient.shared.getOptional("me/player/devices")
        devices = response?.devices ?? []
    }

    func togglePlayPause() async {
        let playing = state?.isPlaying ?? false
        progressState.applyPlaybackStatus(isPlaying: !playing, at: Date())
        await run { try await SpotifyClient.shared.command("PUT", playing ? "me/player/pause" : "me/player/play") }
    }

    func next() async {
        await run { try await SpotifyClient.shared.command("POST", "me/player/next") }
    }

    func loadQueue() async {
        queueIsLoading = true
        defer { queueIsLoading = false }
        do {
            let response: QueueResponse = try await SpotifyClient.shared.get("me/player/queue")
            queue = response.queue
            lastError = nil
        } catch {
            queue = []
            lastError = friendlyMessage(for: error)
        }
    }

    func playNext(_ track: Track) async {
        await run(refreshAfter: false) {
            try await SpotifyClient.shared.command(
                "POST", "me/player/queue", query: ["uri": track.uri])
        }
        await loadQueue()
    }

    func previous() async {
        await run { try await SpotifyClient.shared.command("POST", "me/player/previous") }
    }

    func setShuffle(_ enabled: Bool) async {
        await run {
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
        await run(refreshAfter: false) {
            try await SpotifyClient.shared.command("PUT", "me/player/volume",
                                                   query: ["volume_percent": String(percent)])
        }
    }

    func transferPlayback(to device: Device) async {
        guard let id = device.id else { return }
        await run { try await SpotifyClient.shared.command("PUT", "me/player", body: ["device_ids": [id]]) }
    }

    /// Starts the local librespot engine and moves playback to this Mac, so the
    /// app works standalone with no official Spotify client open anywhere.
    func playOnThisMac() async {
        guard let device = await ensureLocalDevice() else { return }
        await transferPlayback(to: device)
    }

    /// Starts librespot (if needed) and waits until it registers as a Connect
    /// device. Returns the device, or nil after setting `lastError`.
    private func ensureLocalDevice() async -> Device? {
        await localEngine.start()
        guard localEngine.isRunning else {
            if case .failed(let message) = localEngine.status { lastError = message }
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
    }

    /// Play a context (playlist/album) starting at a track, or loose tracks.
    func play(contextURI: String? = nil, trackURI: String? = nil, uris: [String]? = nil) async {
        var body: [String: Any] = [:]
        if let contextURI {
            body["context_uri"] = contextURI
            if let trackURI { body["offset"] = ["uri": trackURI] }
        } else if let uris, !uris.isEmpty {
            body["uris"] = Array(uris.prefix(50))
        } else if let trackURI {
            body["uris"] = [trackURI]
        }
        await run {
            do {
                try await SpotifyClient.shared.command("PUT", "me/player/play", body: body.isEmpty ? nil : body)
            } catch let error as SpotifyAPIError where error.isNoActiveDevice {
                // No active Connect device anywhere: fall back to the local
                // librespot engine and target it explicitly.
                guard let device = await ensureLocalDevice(), let deviceID = device.id else {
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

    private func run(refreshAfter: Bool = true, _ operation: () async throws -> Void) async {
        do {
            try await operation()
            lastError = nil
            if refreshAfter {
                // State takes a moment to propagate on Spotify's backend.
                try? await Task.sleep(for: .milliseconds(400))
                await refresh()
            }
        } catch {
            lastError = friendlyMessage(for: error)
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
