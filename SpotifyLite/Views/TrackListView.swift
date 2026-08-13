import SwiftUI

/// Lista de tracks paginada y perezosa, compartida por playlists y Liked Songs.
struct TrackListView: View {
    let title: String
    /// Path de la Web API que devuelve Paging<TrackItem> (p. ej. "playlists/x/tracks").
    let path: String
    /// context_uri para reproducir dentro del contexto (nil en Liked Songs).
    let contextURI: String?
    var player: PlayerStore

    @State private var tracks: [Track] = []
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("No se pudo cargar", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if tracks.isEmpty && !loading {
                ContentUnavailableView("Sin canciones", systemImage: "music.note")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                            TrackRow(track: track) {
                                Task {
                                    await player.play(contextURI: contextURI,
                                                      trackURI: contextURI == nil ? track.uri : track.uri)
                                }
                            }
                            .onAppear {
                                if index == tracks.count - 1 { Task { await loadMore() } }
                            }
                            Divider().padding(.leading, 56)
                        }
                        if loading { ProgressView().padding() }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(total > 0 ? "\(total) canciones" : "")
        .task(id: path) {
            tracks = []
            total = 0
            error = nil
            await loadMore()
        }
    }

    private func loadMore() async {
        guard !loading, tracks.count < total || total == 0 else { return }
        loading = true
        defer { loading = false }
        do {
            let page: Paging<TrackItem> = try await SpotifyClient.shared.get(
                path, query: ["limit": "100", "offset": String(tracks.count)])
            tracks.append(contentsOf: page.items.compactMap(\.track))
            total = page.total
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct TrackRow: View {
    let track: Track
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: track.artworkURL) { image in
                image.resizable()
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .lineLimit(1)
                Text(track.artistNames)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(track.durationFormatted)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onPlay() }
        .contextMenu {
            Button("Reproducir") { onPlay() }
        }
    }
}
