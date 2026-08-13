import SwiftUI

enum SidebarItem: Hashable {
    case search
    case likedSongs
    case playlist(SimplifiedPlaylist)
}

@MainActor
@Observable
final class LibraryStore {
    private(set) var playlists: [SimplifiedPlaylist] = []
    var lastError: String?

    func loadPlaylists() async {
        do {
            var all: [SimplifiedPlaylist] = []
            var offset = 0
            while true {
                let page: Paging<SimplifiedPlaylist> = try await SpotifyClient.shared.get(
                    "me/playlists", query: ["limit": "50", "offset": String(offset)])
                all.append(contentsOf: page.items)
                offset += page.items.count
                if page.next == nil || page.items.isEmpty { break }
            }
            playlists = all
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}

struct SidebarView: View {
    var library: LibraryStore
    var player: PlayerStore
    @Binding var selection: SidebarItem?
    @Environment(KeyboardController.self) private var keyboard

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Search", systemImage: "magnifyingglass")
                    .tag(SidebarItem.search)
                sidebarLabel(
                    title: "Liked Songs",
                    icon: "heart.fill",
                    isCurrent: player.state?.isPlayingLikedSongs ?? false
                )
                .tag(SidebarItem.likedSongs)
            }
            Section("Playlists") {
                ForEach(library.playlists) { playlist in
                    sidebarLabel(
                        title: playlist.name,
                        icon: "music.note.list",
                        isCurrent: player.state?.isPlayingPlaylist(id: playlist.id) ?? false
                    )
                    .tag(SidebarItem.playlist(playlist))
                }
            }
        }
        .bindAppFocus(.sidebar)
        .onKeyPress(.return) {
            keyboard.perform(.activate)
            return .handled
        }
        .onExitCommand { keyboard.perform(.cancel) }
        .task {
            await library.loadPlaylists()
            keyboard.registerSidebar(playlists: library.playlists)
        }
        .onChange(of: library.playlists.count) { _, _ in
            keyboard.registerSidebar(playlists: library.playlists)
        }
    }

    private func sidebarLabel(title: String, icon: String, isCurrent: Bool) -> some View {
        Label {
            Text(title)
                .lineLimit(1)
        } icon: {
            Image(systemName: isCurrent
                  ? ((player.state?.isPlaying ?? false) ? "speaker.wave.2.fill" : "speaker.fill")
                  : icon)
        }
        .foregroundStyle(isCurrent ? Color.green : Color.primary)
        .help(isCurrent ? "Now playing from \(title)" : title)
    }
}
