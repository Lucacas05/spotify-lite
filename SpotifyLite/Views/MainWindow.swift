import SwiftUI

struct MainWindow: View {
    var auth: AuthManager

    var player: PlayerStore

    @State private var library = LibraryStore()
    @State private var selection: SidebarItem? = .search
    @State private var profile: UserProfile?
    @State private var avatarImage: NSImage?
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("menuBarEnabled") private var menuBarEnabled = false
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        NavigationSplitView {
            SidebarView(library: library, selection: $selection)
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
            avatarImage = await Self.loadAvatar(from: profile?.avatarURL)
            player.startPolling()
        }
        .onChange(of: scenePhase) { _, phase in
            // No timers in the background: 0% CPU at idle.
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

    private var accountMenu: some View {
        Menu {
            Toggle("Menu bar icon", isOn: $menuBarEnabled)
            Menu("Appearance") {
                Button("System") { appearance = "system" }
                Button("Light") { appearance = "light" }
                Button("Dark") { appearance = "dark" }
            }
            Divider()
            Button("Log out") { auth.logout() }
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

    private var colorScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private var keyboardShortcuts: some View {
        Group {
            Button("Search") {
                selection = .search
                NotificationCenter.default.post(name: .focusSpotifySearch, object: nil)
            }
                .keyboardShortcut("f", modifiers: .command)
            Button("Go to Search") { selection = .search }
                .keyboardShortcut("1", modifiers: .command)
            Button("Go to Liked Songs") { selection = .likedSongs }
                .keyboardShortcut("2", modifiers: .command)
            Button("Play or pause") { Task { await player.togglePlayPause() } }
                .keyboardShortcut(.space, modifiers: [])
        }
        // `hidden()` also disables keyboard shortcuts. Keep these buttons in
        // the interaction hierarchy, but out of layout and accessibility.
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
            Button("Dismiss") { player.lastError = nil }
                .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.9))
    }
}
