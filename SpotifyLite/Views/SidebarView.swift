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
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Search", systemImage: "magnifyingglass")
                    .tag(SidebarItem.search)
                Label("Liked Songs", systemImage: "heart.fill")
                    .tag(SidebarItem.likedSongs)
            }
            Section("Playlists") {
                ForEach(library.playlists) { playlist in
                    Label(playlist.name, systemImage: "music.note.list")
                        .tag(SidebarItem.playlist(playlist))
                }
            }
        }
        .task { await library.loadPlaylists() }
    }
}
