import SwiftUI

struct MainWindow: View {
    var auth: AuthManager

    var player: PlayerStore

    @State private var library = LibraryStore()
    @State private var keyboard = KeyboardController()
    @State private var selection: SidebarItem? = .search
    @State private var profile: UserProfile?
    @State private var avatarImage: NSImage?
    @FocusState private var focus: AppFocus?
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("menuBarEnabled") private var menuBarEnabled = false
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView(library: library, player: player, selection: $selection)
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220)
            } detail: {
                NavigationStack {
                    detailView
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                accountMenu
                            }
                        }
                }
            }

            if auth.isSessionExpired {
                sessionExpiredBanner
            } else if let error = player.lastError {
                errorBanner(error)
            }
            PlayerBarView(player: player)
        }
        .overlay {
            if keyboard.navigation.commandPaletteOpen {
                CommandPaletteView(keyboard: keyboard, player: player)
            }
            if keyboard.navigation.cheatsheetOpen {
                CheatsheetView(keyboard: keyboard)
            }
        }
        .sheet(isPresented: Bindable(player).localSetupNeeded) {
            LibrespotSetupView(player: player)
        }
        .preferredColorScheme(colorScheme)
        .background { GlobalKeyboardShortcuts(keyboard: keyboard) }
        // Applied to the outer layout so PlayerBarView and the
        // palette/cheatsheet subtrees also see the controller.
        .environment(keyboard)
        .environment(\.appFocus, $focus)
        .onChange(of: keyboard.navigation) { _, _ in
            if focus != keyboard.focusTarget {
                focus = keyboard.focusTarget
            }
        }
        .onChange(of: focus) { _, newFocus in
            keyboard.applyNativeFocus(newFocus)
        }
        .onChange(of: keyboard.navigation.sidebarIndex) { _, index in
            guard keyboard.sidebarItems.indices.contains(index) else { return }
            let item = keyboard.sidebarItems[index]
            if selection != item, keyboard.navigation.zone == .sidebar {
                selection = item
            }
        }
        .onChange(of: selection) { _, newSelection in
            if let newSelection, let index = keyboard.sidebarItems.firstIndex(of: newSelection) {
                keyboard.navigation.sidebarIndex = index
            }
        }
        .onAppear {
            keyboard.player = player
            keyboard.onSelectSidebarItem = { selection = $0 }
            keyboard.registerSidebar(playlists: library.playlists)
            focus = keyboard.focusTarget
        }
        .onChange(of: library.playlists.count) { _, _ in
            keyboard.registerSidebar(playlists: library.playlists)
        }
        .frame(minWidth: 800, minHeight: 500)
        .task {
            profile = try? await SpotifyClient.shared.get("me")
            avatarImage = await Self.loadAvatar(from: profile?.avatarURL)
            player.setSceneActive(true)
        }
        .onChange(of: scenePhase) { _, phase in
            player.setSceneActive(phase == .active)
        }
        .onChange(of: auth.isSessionExpired) { _, expired in
            if expired { player.haltForDeadSession() }
        }
        .onDisappear { player.setSceneActive(false) }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .search, nil:
            SearchView(player: player)
        case .likedSongs:
            TrackListView(title: "Liked Songs", source: .likedSongs, player: player)
        case .playlist(let playlist):
            TrackListView(
                title: playlist.name,
                source: .playlist(id: playlist.id),
                player: player,
                artworkURL: playlistArtworkURL(playlist)
            )
        }
    }

    private var accountMenu: some View {
        Menu {
            Toggle("Menu bar icon", isOn: $menuBarEnabled)
            Menu("Appearance") {
                Button("System") { appearance = "system" }
                Button("Light") { appearance = "light" }
                Button("Dark") { appearance = "dark" }
            }
            Divider()
            Button("Log out") { signOut() }
        } label: {
            HStack(spacing: 6) {
                profileAvatar
                Text(profile?.displayName ?? "Account")
                    .font(.callout)
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Account")
        .accessibilityHint(profile?.displayName ?? "Open account menu")
        .help("Account")
    }

    // A toolbar Menu label ignores SwiftUI size modifiers on async images, so
    // the avatar is pre-rendered as a fixed-size circular NSImage.
    private var profileAvatar: some View {
        Group {
            if let avatarImage {
                Image(nsImage: avatarImage)
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.green)
            }
        }
        .accessibilityHidden(true)
    }

    private static func loadAvatar(from url: URL?) async -> NSImage? {
        guard let url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let source = NSImage(data: data) else { return nil }

        let side: CGFloat = 24
        let rendered = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            // Aspect-fill: crop the source to a centered square before drawing.
            let sourceSide = min(source.size.width, source.size.height)
            let sourceRect = NSRect(
                x: (source.size.width - sourceSide) / 2,
                y: (source.size.height - sourceSide) / 2,
                width: sourceSide, height: sourceSide
            )
            source.draw(in: rect, from: sourceRect, operation: .sourceOver, fraction: 1)
            return true
        }
        return rendered
    }

    private func playlistArtworkURL(_ playlist: SimplifiedPlaylist) -> URL? {
        playlist.images?
            .max(by: { ($0.width ?? 0) < ($1.width ?? 0) })
            .flatMap { URL(string: $0.url) }
    }

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private func signOut() {
        player.handleSignOut()
        auth.logout()
    }

    private var sessionExpiredBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(SpotifyAPIError.sessionExpiredMessage)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            Button("Cerrar sesión") { signOut() }
                .buttonStyle(.plain)
                .fontWeight(.semibold)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.9))
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            if player.canRetryLocalPlayback(for: message) {
                Button("Retry") {
                    player.lastError = nil
                    Task { await player.playOnThisMac() }
                }
                .buttonStyle(.plain)
                .fontWeight(.semibold)
            }
            Button("Dismiss") { player.lastError = nil }
                .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.9))
    }
}
