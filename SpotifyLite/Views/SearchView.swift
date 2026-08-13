import SwiftUI

struct SearchView: View {
    var player: PlayerStore

    @State private var query = ""
    @State private var results: [Track] = []
    @State private var searching = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            TextField("Buscar canciones…", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)

            if let error {
                ContentUnavailableView("Error al buscar", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if results.isEmpty {
                ContentUnavailableView(query.isEmpty ? "Busca en Spotify" : (searching ? "Buscando…" : "Sin resultados"),
                                       systemImage: "magnifyingglass")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { track in
                            TrackRow(track: track) {
                                Task { await player.play(trackURI: track.uri) }
                            }
                            Divider().padding(.leading, 56)
                        }
                    }
                }
            }
        }
        .navigationTitle("Buscar")
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                results = []
                error = nil
                return
            }
            // Debounce: si el usuario sigue escribiendo, esta task se cancela.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            do {
                let response: SearchResponse = try await SpotifyClient.shared.get(
                    "search", query: ["q": trimmed, "type": "track", "limit": "10"])
                results = response.tracks?.items ?? []
                error = nil
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
