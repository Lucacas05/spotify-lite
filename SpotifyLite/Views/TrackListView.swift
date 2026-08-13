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
    var artworkURL: URL? = nil

    @State private var tracks: [Track] = []
    @State private var total = 0
    @State private var loadedItemCount = 0
    @State private var loading = false
    @State private var error: String?

    private var contextURI: String? {
        if case .playlist(let id) = source { return "spotify:playlist:\(id)" }
        return nil
    }

    private var header: some View {
        TrackListHeader(
            title: title,
            source: source,
            artworkURL: artworkURL ?? tracks.first?.artworkURL,
            total: total,
            tracks: tracks,
            player: player
        )
    }

    var body: some View {
        Group {
            if let error {
                ContentUnavailableView("Could not load", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if tracks.isEmpty && !loading {
                VStack(spacing: 0) {
                    header
                    ContentUnavailableView("No songs", systemImage: "music.note")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        header
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

private struct TrackListHeader: View {
    let title: String
    let source: TrackListSource
    var artworkURL: URL?
    var total: Int
    var tracks: [Track]
    var player: PlayerStore

    var body: some View {
        HStack(alignment: .bottom, spacing: 20) {
            headerArtwork
            VStack(alignment: .leading, spacing: 8) {
                Text(source == .likedSongs ? "LIBRARY" : "PLAYLIST")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.largeTitle.bold())
                    .lineLimit(2)
                if total > 0 {
                    Text("\(total) songs")
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button {
                        Task { await playFromStart(shuffled: false) }
                    } label: {
                        Label(isPlayingThis ? "Pause" : "Play",
                              systemImage: isPlayingThis ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .help(isPlayingThis ? "Pause" : "Play")
                    .disabled(!canPlay)

                    Button {
                        Task { await playFromStart(shuffled: true) }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                    }
                    .buttonStyle(.bordered)
                    .help("Shuffle play")
                    .disabled(!canPlay)
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var headerArtwork: some View {
        if let artworkURL {
            AsyncImage(url: artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.secondary.opacity(0.2)
            }
            .frame(width: 140, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(source == .likedSongs ? Color.pink.opacity(0.85) : Color.secondary.opacity(0.2))
                    .frame(width: 140, height: 140)
                Image(systemName: source == .likedSongs ? "heart.fill" : "music.note.list")
                    .font(.system(size: 44))
                    .foregroundStyle(source == .likedSongs ? .white : .secondary)
            }
        }
    }

    private var canPlay: Bool {
        contextURI != nil || !tracks.isEmpty
    }

    private var contextURI: String? {
        if case .playlist(let id) = source { return "spotify:playlist:\(id)" }
        return nil
    }

    private var isPlayingThis: Bool {
        guard let contextURI else { return false }
        return (player.state?.context?.uri == contextURI) && (player.state?.isPlaying ?? false)
    }

    private func playFromStart(shuffled: Bool) async {
        if isPlayingThis && !shuffled {
            await player.togglePlayPause()
            return
        }
        if let contextURI {
            // Start on a random track so the first song is shuffled too, then
            // enable shuffle once playback made a device active. Setting
            // shuffle first fails with 404 when no device is active yet.
            let startURI = shuffled ? tracks.randomElement()?.uri : nil
            await player.play(contextURI: contextURI, trackURI: startURI)
        } else {
            let uris = shuffled ? tracks.shuffled() : tracks
            await player.play(uris: uris.prefix(50).map(\.uri))
        }
        if player.lastError == nil {
            await player.setShuffle(shuffled)
        }
    }
}

struct TrackRow: View {
    let track: Track
    var player: PlayerStore
    var showAlbumLink = true
    let onPlay: () -> Void

    private var isCurrent: Bool {
        player.state?.isCurrentTrack(track) ?? false
    }

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
                    .foregroundStyle(isCurrent ? Color.green : Color.primary)
                    .fontWeight(isCurrent ? .semibold : .regular)
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
        .background {
            if isCurrent {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.green.opacity(0.12))
            }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityValue(isCurrent ? "Now playing" : "")
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
