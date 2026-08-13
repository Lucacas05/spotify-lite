import SwiftUI
import AppKit

enum TrackListSource: Equatable {
    /// First page comes from GET /playlists/{id}; later pages are
    /// fetched from /playlists/{id}/items using their offset.
    case playlist(id: String)
    /// GET /me/tracks, paginated with a maximum limit of 50.
    case likedSongs
}

/// Tracks the raw Spotify page offset separately from playable tracks. Page
/// entries may contain a null track, but those entries still consume offsets.
struct TrackPagingCursor: Equatable {
    private(set) var offset = 0
    private(set) var total = 0
    private(set) var hasMore = true

    mutating func reset() {
        self = TrackPagingCursor()
    }

    mutating func advance(rawItemCount: Int, total: Int, next: String?) {
        let consumed = max(rawItemCount, 0)
        offset += consumed
        self.total = max(total, 0)
        // A malformed empty page must not retry the same offset forever.
        hasMore = consumed > 0 && next != nil
    }
}

/// Track list shared by playlists and Liked Songs.
struct TrackListView: View {
    let title: String
    let source: TrackListSource
    var player: PlayerStore
    var artworkURL: URL? = nil

    @State private var tracks: [Track] = []
    @State private var paging = TrackPagingCursor()
    @State private var loading = false
    @State private var loadGeneration = 0
    @State private var error: String?
    @Environment(KeyboardController.self) private var keyboard

    private var contextURI: String? {
        if case .playlist(let id) = source { return "spotify:playlist:\(id)" }
        return nil
    }

    private var header: some View {
        TrackListHeader(
            title: title,
            source: source,
            artworkURL: artworkURL ?? tracks.first?.artworkURL,
            total: paging.total,
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            header
                            ForEach(tracks.indices, id: \.self) { index in
                                let track = tracks[index]
                                TrackRow(track: track, player: player, keyboardIndex: index) {
                                    Task { await player.play(contextURI: contextURI, trackURI: track.uri) }
                                }
                                .id(index)
                                Divider().padding(.leading, 56)
                            }
                            if paging.hasMore, paging.offset > 0 {
                                ProgressView()
                                    .padding()
                                    // One sentinel replaces 30 per-row tasks. A new
                                    // offset gives each page exactly one load trigger.
                                    .task(id: paging.offset) {
                                        await loadMore(generation: loadGeneration)
                                    }
                            } else if loading {
                                ProgressView().padding()
                            }
                        }
                    }
                    .onChange(of: keyboard.navigation.listIndex) { _, index in
                        if keyboard.navigation.zone == .list {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(paging.total > 0 ? "\(paging.total) songs" : "")
        .onAppear { registerKeyboardList() }
        .onChange(of: tracks.count) { _, _ in registerKeyboardList() }
        .task(id: source) {
            loadGeneration += 1
            let generation = loadGeneration
            tracks = []
            paging.reset()
            loading = false
            error = nil
            await loadMore(generation: generation)
        }
    }

    private func registerKeyboardList() {
        let currentTracks = $tracks
        keyboard.registerList(count: tracks.count, trackAt: { index in
            let values = currentTracks.wrappedValue
            return values.indices.contains(index) ? values[index] : nil
        }) { track in
            Task { await player.play(contextURI: contextURI, trackURI: track.uri) }
        }
    }

    private func loadMore(generation: Int) async {
        guard generation == loadGeneration, !loading, paging.hasMore else { return }
        loading = true
        defer {
            if generation == loadGeneration { loading = false }
        }
        do {
            switch source {
            case .playlist(let id):
                // The detail contains the first page (100 items in the
                // current API). Later pages live under /items.
                let page: Paging<PlaylistEntry>
                if paging.offset == 0 {
                    let response: PlaylistDetailResponse = try await SpotifyClient.shared.get(
                        "playlists/\(id)")
                    page = response.items
                } else {
                    page = try await SpotifyClient.shared.get(
                        "playlists/\(id)/items",
                        query: ["limit": "100", "offset": String(paging.offset)])
                }

                guard !Task.isCancelled, generation == loadGeneration else { return }
                loading = false
                tracks.append(contentsOf: page.items.compactMap(\.item))
                paging.advance(rawItemCount: page.items.count, total: page.total, next: page.next)
            case .likedSongs:
                let page: Paging<TrackItem> = try await SpotifyClient.shared.get(
                    "me/tracks", query: ["limit": "50", "offset": String(paging.offset)])
                guard !Task.isCancelled, generation == loadGeneration else { return }
                loading = false
                tracks.append(contentsOf: page.items.compactMap(\.track))
                paging.advance(rawItemCount: page.items.count, total: page.total, next: page.next)
            }
        } catch is CancellationError {
        } catch {
            if generation == loadGeneration, !Task.isCancelled {
                self.error = error.localizedDescription
            }
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
    var keyboardIndex: Int? = nil
    var keyboardZone: FocusZone = .list
    let onPlay: () -> Void

    @Environment(KeyboardController.self) private var keyboard

    private var isCurrent: Bool {
        player.state?.isCurrentTrack(track) ?? false
    }

    private var isKeyboardSelected: Bool {
        guard let keyboardIndex else { return false }
        return keyboard.isSelected(zone: keyboardZone, index: keyboardIndex)
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
            if isKeyboardSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.green.opacity(0.18))
            } else if isCurrent {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.green.opacity(0.12))
            }
        }
        .keyboardSelected(isKeyboardSelected)
        .contentShape(Rectangle())
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityValue(isCurrent ? "Now playing" : "")
        .onTapGesture(count: 2) { onPlay() }
        .contextMenu { trackMenuItems }
        .background {
            // The context-menu bridge only exists for the selected row. Long
            // lists therefore keep one native capture instead of one per item.
            if let keyboardIndex, isKeyboardSelected {
                TrackRowViewCapture(
                    focus: keyboardZone == .queue
                        ? .queueRow(keyboardIndex)
                        : .listRow(keyboardIndex),
                    keyboard: keyboard
                )
            }
        }
        .modifier(TrackRowKeyboard(
            index: keyboardIndex,
            zone: keyboardZone,
            isSelected: isKeyboardSelected
        ))
    }

    @ViewBuilder
    private var trackMenuItems: some View {
        Button("Play") { onPlay() }
        Button("Play next") { Task { await player.playNext(track) } }
        if showAlbumLink, let album = track.album, let albumID = album.id {
            NavigationLink("View album") {
                AlbumDetailView(albumID: albumID, albumName: album.name, player: player)
            }
        }
        if let artist = track.artists.first, let artistID = artist.id {
            NavigationLink("View artist") {
                ArtistDetailView(artistID: artistID, artistName: artist.name, player: player)
            }
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

/// Registers the row's native host without mutating SwiftUI state. The old
/// capture scheduled an async @State write and a notification subscription on
/// every row, which forced long LazyVStacks to retain their entire view graph.
private struct TrackRowViewCapture: NSViewRepresentable {
    let focus: AppFocus
    var keyboard: KeyboardController

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        keyboard.registerNativeView(view, for: focus)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        keyboard.registerNativeView(nsView, for: focus)
    }
}

private struct TrackRowKeyboard: ViewModifier {
    var index: Int?
    var zone: FocusZone
    var isSelected: Bool

    func body(content: Content) -> some View {
        // Logical selection lives in KeyboardController. Only its current row
        // needs a native focus responder; making every row focusable retained
        // thousands of FocusState graph nodes in long playlists.
        if let index, isSelected {
            content.keyboardNavigable(focus: zone == .queue ? .queueRow(index) : .listRow(index))
        } else {
            content
        }
    }
}
