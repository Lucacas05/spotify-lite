import SwiftUI

struct MainWindow: View {
    var auth: AuthManager

    var player: PlayerStore

    @State private var library = LibraryStore()
    @State private var selection: SidebarItem? = .search
    @State private var profile: UserProfile?
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("menuBarEnabled") private var menuBarEnabled = false
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        NavigationSplitView {
            SidebarView(library: library, selection: $selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
                .safeAreaInset(edge: .bottom) {
                    accountFooter
                }
        } detail: {
            NavigationStack {
                detailView
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let error = player.lastError {
                    errorBanner(error)
                }
                PlayerBarView(player: player)
            }
        }
        .preferredColorScheme(colorScheme)
        .background { keyboardShortcuts }
        .frame(minWidth: 800, minHeight: 500)
        .task {
            profile = try? await SpotifyClient.shared.get("me")
            player.startPolling()
        }
        .onChange(of: scenePhase) { _, phase in
            // Sin timers en background: 0% CPU en reposo.
            if phase == .active { player.startPolling() } else { player.stopPolling() }
        }
        .onDisappear { player.stopPolling() }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .search, nil:
            SearchView(player: player)
        case .likedSongs:
            TrackListView(title: "Liked Songs", source: .likedSongs, player: player)
        case .playlist(let playlist):
            TrackListView(title: playlist.name, source: .playlist(id: playlist.id), player: player)
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
                Toggle("Icono en la barra de menús", isOn: $menuBarEnabled)
                Menu("Apariencia") {
                    Button("Sistema") { appearance = "system" }
                    Button("Claro") { appearance = "light" }
                    Button("Oscuro") { appearance = "dark" }
                }
                Divider()
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

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private var keyboardShortcuts: some View {
        Group {
            Button("Buscar") {
                selection = .search
                NotificationCenter.default.post(name: .focusSpotifySearch, object: nil)
            }
                .keyboardShortcut("f", modifiers: .command)
            Button("Ir a Buscar") { selection = .search }
                .keyboardShortcut("1", modifiers: .command)
            Button("Ir a Liked Songs") { selection = .likedSongs }
                .keyboardShortcut("2", modifiers: .command)
            Button("Reproducir o pausar") { Task { await player.togglePlayPause() } }
                .keyboardShortcut(.space, modifiers: [])
        }
        // `hidden()` también desactiva los keyboard shortcuts. Mantener estos
        // botones en la jerarquía de interacción, pero fuera del layout y AX.
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button("Cerrar") { player.lastError = nil }
                .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.9))
    }
}
