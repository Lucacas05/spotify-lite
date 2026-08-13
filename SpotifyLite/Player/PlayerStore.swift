import Foundation
import Observation

@MainActor
@Observable
final class PlayerStore {
    private(set) var state: PlaybackState?
    private(set) var devices: [Device] = []
    var lastError: String?

    private var pollTask: Task<Void, Never>?

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
            state = try await SpotifyClient.shared.getOptional("me/player")
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
        await run { try await SpotifyClient.shared.command("PUT", playing ? "me/player/pause" : "me/player/play") }
    }

    func next() async {
        await run { try await SpotifyClient.shared.command("POST", "me/player/next") }
    }

    func previous() async {
        await run { try await SpotifyClient.shared.command("POST", "me/player/previous") }
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
            lastError = error.localizedDescription
        }
    }
}
