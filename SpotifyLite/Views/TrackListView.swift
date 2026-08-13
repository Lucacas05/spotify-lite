import SwiftUI

enum TrackListSource: Equatable {
    /// First page comes from GET /playlists/{id}; later pages are
    /// fetched from /playlists/{id}/items using their offset.
    case playlist(id: String)
    /// GET /me/tracks, paginated with a maximum limit of 50.
    case likedSongs
}

/// Track list shared by playlists and Liked Songs.
struct TrackListView: View {
    let title: String
    let source: TrackListSource
    var player: PlayerStore

    @State private var tracks: [Track] = []
    @State private var total = 0
    @State private var loadedItemCount = 0
    @State private var loading = false
    @State private var error: String?

    private var contextURI: String? {
        if case .playlist(let id) = source { return "spotify:playlist:\(id)" }
        return nil
    }

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("Could not load", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if tracks.isEmpty && !loading {
                ContentUnavailableView("No songs", systemImage: "music.note")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                            TrackRow(track: track, player: player) {
                                Task { await player.play(contextURI: contextURI, trackURI: track.uri) }
                            }
                            .onAppear {
                                // Fallback for slow connections or an interrupted
                                // preload: request the next page before hitting the bottom.
                                if index >= tracks.count - 30 {
                                    Task { await loadMore() }
                                }
                            }
                            Divider().padding(.leading, 56)
                        }
                        if loading { ProgressView().padding() }
                    }
                    // Keep the last row fully above the player bar,
                    // which lives outside this ScrollView.
                    .padding(.bottom, 72)
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(total > 0 ? "\(total) songs" : "")
        .task(id: source) {
            tracks = []
            total = 0
            loadedItemCount = 0
            error = nil
            await loadMore()
            await preloadRemainingPlaylistItems()
        }
    }

    private func loadMore() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            switch source {
            case .playlist(let id):
                guard loadedItemCount < total || total == 0 else { return }

                // The detail contains the first page (100 items in the
                // current API). Later pages live under /items.
                let page: Paging<PlaylistEntry>
                if loadedItemCount == 0 {
                    let response: PlaylistDetailResponse = try await SpotifyClient.shared.get(
                        "playlists/\(id)")
                    page = response.items
                } else {
                    page = try await SpotifyClient.shared.get(
                        "playlists/\(id)/items",
                        query: ["limit": "100", "offset": String(loadedItemCount)])
                }

                tracks.append(contentsOf: page.items.compactMap(\.item))
                loadedItemCount += page.items.count
                total = page.total
            case .likedSongs:
                guard tracks.count < total || total == 0 else { return }
                let page: Paging<TrackItem> = try await SpotifyClient.shared.get(
                    "me/tracks", query: ["limit": "50", "offset": String(tracks.count)])
                tracks.append(contentsOf: page.items.compactMap(\.track))
                total = page.total
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Show the first page as soon as possible and finish the rest in the
    /// background, yielding to SwiftUI between requests.
    private func preloadRemainingPlaylistItems() async {
        guard case .playlist = source else { return }

        while loadedItemCount < total, !Task.isCancelled, error == nil {
            let previousCount = loadedItemCount
            await loadMore()
            guard loadedItemCount > previousCount else { break }
            await Task.yield()
        }
    }
}

struct TrackRow: View {
    let track: Track
    var player: PlayerStore
    var showAlbumLink = true
    let onPlay: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if showAlbumLink, let album = track.album, let albumID = album.id {
                NavigationLink {
                    AlbumDetailView(albumID: albumID, albumName: album.name, player: player)
                } label: {
                    artwork
                }
                .buttonStyle(.plain)
                .help("View album \(album.name)")
            } else {
                artwork
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .lineLimit(1)
                if let artist = track.artists.first, let artistID = artist.id {
                    NavigationLink {
                        ArtistDetailView(artistID: artistID, artistName: artist.name, player: player)
                    } label: {
                        Text(track.artistNames)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("View artist \(artist.name)")
                } else {
                    Text(track.artistNames)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Button {
                Task { await player.playNext(track) }
            } label: {
                Image(systemName: "text.line.last.and.arrowtriangle.forward")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Play next")
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
            Button("Play") { onPlay() }
            Button("Play next") { Task { await player.playNext(track) } }
        }
    }

    private var artwork: some View {
        AsyncImage(url: track.artworkURL) { image in
            image.resizable()
        } placeholder: {
            Color.secondary.opacity(0.2)
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
