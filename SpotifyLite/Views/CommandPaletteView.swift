import SwiftUI

private enum PaletteItem: Identifiable {
    case action(KeyboardAction, String, String)
    case sidebar(SidebarItem, String)
    case track(Track)
    case device(Device)

    var id: String {
        switch self {
        case .action(let action, _, _): return "action-\(action.rawValue)"
        case .sidebar(let item, _):
            switch item {
            case .search: return "sidebar-search"
            case .likedSongs: return "sidebar-liked"
            case .playlist(let playlist): return "sidebar-playlist-\(playlist.id)"
            }
        case .track(let track): return "track-\(track.id ?? track.uri)"
        case .device(let device): return "device-\(device.id ?? device.name)"
        }
    }

    var title: String {
        switch self {
        case .action(_, let title, _): return title
        case .sidebar(_, let title): return title
        case .track(let track): return track.name
        case .device(let device): return device.name
        }
    }

    var subtitle: String {
        switch self {
        case .action(_, _, let subtitle): return subtitle
        case .sidebar: return "Go to"
        case .track(let track): return track.artistNames
        case .device(let device): return device.isActive ? "Active device" : device.type
        }
    }

    var systemImage: String {
        switch self {
        case .action(let action, _, _):
            switch action {
            case .playPause: return "playpause.fill"
            case .nextTrack: return "forward.end.fill"
            case .previousTrack: return "backward.end.fill"
            case .toggleShuffle: return "shuffle"
            default: return "command"
            }
        case .sidebar(.search, _): return "magnifyingglass"
        case .sidebar(.likedSongs, _): return "heart.fill"
        case .sidebar(.playlist, _): return "music.note.list"
        case .track: return "music.note"
        case .device: return "hifispeaker"
        }
    }
}

struct CommandPaletteView: View {
    var keyboard: KeyboardController
    var player: PlayerStore

    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var remoteTracks: [Track] = []
    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { keyboard.perform(.cancel) }

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    textField
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Divider()

                if items.isEmpty {
                    Text(query.isEmpty ? "Type to filter commands" : "No matches")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                    paletteRow(item, index: index)
                                        .id(index)
                                }
                            }
                        }
                        .onChange(of: selectedIndex) { _, index in
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                }

                Divider()
                HStack {
                    Text("↑↓ navigate")
                    Text("Enter select")
                    Text("Esc close")
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
            }
            .frame(width: 520)
            .frame(maxHeight: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
        }
        .onAppear { selectedIndex = 0 }
        .task(id: query) { await searchTracks() }
        .onChange(of: items.count) { _, _ in
            selectedIndex = min(selectedIndex, max(items.count - 1, 0))
        }
    }

    private var textField: some View {
        TextField("Search playlists, tracks, and actions…", text: $query)
            .textFieldStyle(.plain)
            .bindAppFocus(.commandPalette)
            .onSubmit { activateSelection() }
            .onMoveCommand { direction in
                switch direction {
                case .up: moveSelection(-1)
                case .down: moveSelection(1)
                default: break
                }
            }
            .onExitCommand { keyboard.perform(.cancel) }
    }

    private func paletteRow(_ item: PaletteItem, index: Int) -> some View {
        Button {
            selectedIndex = index
            activateSelection()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: item.systemImage)
                    .frame(width: 18)
                    .foregroundStyle(index == selectedIndex ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(index == selectedIndex ? Color.green.opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var items: [PaletteItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var result: [PaletteItem] = []

        let actions: [PaletteItem] = [
            .action(.playPause, "Play / Pause", "Playback"),
            .action(.nextTrack, "Next track", "Playback"),
            .action(.previousTrack, "Previous track", "Playback"),
            .action(.toggleShuffle, player.isShuffling ? "Disable shuffle" : "Enable shuffle", "Playback"),
            .action(.focusSearch, "Search", "Navigation"),
        ]
        result.append(contentsOf: actions.filter { needle.isEmpty || $0.title.lowercased().contains(needle) })

        result.append(contentsOf: keyboard.sidebarItems.compactMap { item -> PaletteItem? in
            let title: String
            switch item {
            case .search: title = "Search"
            case .likedSongs: title = "Liked Songs"
            case .playlist(let playlist): title = playlist.name
            }
            if !needle.isEmpty && !title.lowercased().contains(needle) { return nil }
            return .sidebar(item, title)
        })

        if !needle.isEmpty {
            result.append(contentsOf: remoteTracks.map { .track($0) })
        }

        result.append(contentsOf: player.devices.compactMap { device -> PaletteItem? in
            if !needle.isEmpty && !device.name.lowercased().contains(needle) { return nil }
            return .device(device)
        })

        return result
    }

    private func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + items.count) % items.count
    }

    private func activateSelection() {
        guard items.indices.contains(selectedIndex) else { return }
        let item = items[selectedIndex]
        keyboard.perform(.cancel)
        switch item {
        case .action(let action, _, _):
            keyboard.perform(action)
        case .sidebar(let sidebarItem, _):
            keyboard.onSelectSidebarItem?(sidebarItem)
            if sidebarItem == .search {
                keyboard.perform(.focusSearch)
            } else {
                keyboard.perform(.focusTrackList)
            }
        case .track(let track):
            Task { await player.play(trackURI: track.uri) }
        case .device(let device):
            Task { await player.transferPlayback(to: device) }
        }
    }

    private func searchTracks() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            remoteTracks = []
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        do {
            let response: SearchResponse = try await SpotifyClient.shared.get(
                "search", query: ["q": trimmed, "type": "track", "limit": "10"])
            remoteTracks = response.tracks?.items ?? []
        } catch is CancellationError {
        } catch {
            remoteTracks = []
        }
    }
}
