import SwiftUI

@main
struct SpotifyLiteApp: App {
    @State private var auth = AuthManager()
    @State private var player = PlayerStore()
    @AppStorage("menuBarEnabled") private var menuBarEnabled = false

    init() {
        // Artwork cache: minimal in RAM, 50 MB on disk.
        URLCache.shared = URLCache(memoryCapacity: 2 * 1024 * 1024,
                                   diskCapacity: 50 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(auth: auth, player: player)
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification)) { _ in
                    // Don't leave the librespot child playing after the app quits.
                    player.stopLocalPlayback()
                }
        }

        MenuBarExtra(isInserted: $menuBarEnabled) {
            MenuBarPlayerView(auth: auth, player: player)
        } label: {
            Label(player.state?.item?.name ?? "SpotifyLite", systemImage: "music.note")
        }
        .menuBarExtraStyle(.window)
    }
}
