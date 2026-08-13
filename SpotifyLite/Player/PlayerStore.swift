import Foundation
import Observation

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
        // Comparar contra la posición interpolada, no contra el target original:
        // si Spotify ya aplicó el seek, el remoto avanza con el tiempo y se alejaría
        // del target aunque la confirmación sea correcta.
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

    private var pollTask: Task<Void, Never>?
    private var progressState = PlaybackProgressState()
    private var seekRequestID = 0

    var currentTrackIdentifier: String? {
        state?.item?.id ?? state?.item?.uri
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

    /// Reproduce un contexto (playlist/álbum) empezando en un track, o tracks sueltos.
    func play(contextURI: String? = nil, trackURI: String? = nil) async {
        var body: [String: Any] = [:]
        if let contextURI {
            body["context_uri"] = contextURI
            if let trackURI { body["offset"] = ["uri": trackURI] }
        } else if let trackURI {
            body["uris"] = [trackURI]
        }
        await run { try await SpotifyClient.shared.command("PUT", "me/player/play", body: body.isEmpty ? nil : body) }
    }

    func progress(at date: Date = .now) -> Int {
        progressState.progress(at: date)
    }

    private func run(refreshAfter: Bool = true, _ operation: () async throws -> Void) async {
        do {
            try await operation()
            lastError = nil
            if refreshAfter {
                // El estado tarda un poco en propagarse en el backend de Spotify.
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
            case 401: return "Tu sesión de Spotify caducó. Cierra sesión y vuelve a entrar."
            case 403: return "Spotify rechazó el control. Comprueba que tu cuenta sea Premium y que haya un dispositivo activo."
            case 404: return "No hay ningún dispositivo Spotify activo. Abre Spotify en un dispositivo e inténtalo de nuevo."
            default: break
            }
        }
        if (error as? URLError) != nil {
            return "Sin conexión con Spotify. Comprueba tu conexión a internet."
        }
        return error.localizedDescription
    }
}
