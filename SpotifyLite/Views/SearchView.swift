import SwiftUI

extension Notification.Name {
    static let focusSpotifySearch = Notification.Name("focusSpotifySearch")
}

struct SearchView: View {
    var player: PlayerStore

    @State private var query = ""
    @State private var results: [Track] = []
    @State private var searching = false
    @State private var error: String?
    @Environment(KeyboardController.self) private var keyboard

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search songs…", text: $query)
                .textFieldStyle(.roundedBorder)
                .bindAppFocus(.searchField)
                .onSubmit { keyboard.perform(.activate) }
                .onMoveCommand { direction in
                    if direction == .down { keyboard.perform(.moveDown) }
                }
                .onExitCommand { keyboard.perform(.cancel) }
                .onKeyPress(.escape) {
                    keyboard.perform(.cancel)
                    return .handled
                }
                .padding(12)

            if let error {
                ContentUnavailableView("Search failed", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if results.isEmpty {
                ContentUnavailableView(query.isEmpty ? "Search Spotify" : (searching ? "Searching…" : "No results"),
                                       systemImage: "magnifyingglass")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(results.indices, id: \.self) { index in
                                let track = results[index]
                                TrackRow(track: track, player: player, keyboardIndex: index) {
                                    Task { await player.play(trackURI: track.uri) }
                                }
                                .id(index)
                                Divider().padding(.leading, 56)
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
        .navigationTitle("Search")
        .onAppear {
            if keyboard.navigation.zone != .list {
                keyboard.navigation.zone = .search
            }
            registerKeyboardList()
        }
        .onChange(of: results.count) { _, _ in registerKeyboardList() }
        .onReceive(NotificationCenter.default.publisher(for: .focusSpotifySearch)) { _ in
            keyboard.navigation.zone = .search
        }
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                results = []
                error = nil
                return
            }
            // Debounce: if the user keeps typing, this task is cancelled.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            do {
                let response: SearchResponse = try await SpotifyClient.shared.get(
                    "search", query: ["q": trimmed, "type": "track", "limit": "10"])
                results = response.tracks?.items ?? []
                error = nil
                registerKeyboardList()
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func registerKeyboardList() {
        let currentResults = $results
        keyboard.registerList(count: results.count, trackAt: { index in
            let values = currentResults.wrappedValue
            return values.indices.contains(index) ? values[index] : nil
        }) { track in
            Task { await player.play(trackURI: track.uri) }
        }
    }
}
