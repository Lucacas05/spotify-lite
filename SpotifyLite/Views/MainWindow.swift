import SwiftUI

struct MainWindow: View {
    var auth: AuthManager

    @State private var library = LibraryStore()
    @State private var player = PlayerStore()
    @State private var selection: SidebarItem? = .search
    @State private var profile: UserProfile?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            SidebarView(library: library, selection: $selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
                .safeAreaInset(edge: .bottom) {
                    accountFooter
                }
        } detail: {
            detailView
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PlayerBarView(player: player)
        }
        .frame(minWidth: 800, minHeight: 500)
        .task {
            profile = try? await SpotifyClient.shared.get("me")
            player.startPolling()
        }
        .onChange(of: scenePhase) { _, phase in
            // Sin timers en background: 0% CPU en reposo.
            if phase == .active { player.startPolling() } else { player.stopPolling() }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .search, nil:
            SearchView(player: player)
        case .likedSongs:
            TrackListView(title: "Liked Songs", path: "me/tracks", contextURI: nil, player: player)
        case .playlist(let playlist):
            TrackListView(title: playlist.name,
                          path: "playlists/\(playlist.id)/tracks",
                          contextURI: "spotify:playlist:\(playlist.id)",
                          player: player)
        }
    }

    private var accountFooter: some View {
        HStack {
            Image(systemName: "person.circle.fill")
                .foregroundStyle(.green)
            Text(profile?.displayName ?? "")
                .font(.callout)
                .lineLimit(1)
            Spacer()
            Menu {
                Button("Cerrar sesión") { auth.logout() }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(10)
        .background(.bar)
    }
}
