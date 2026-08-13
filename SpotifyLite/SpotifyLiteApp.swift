import AppKit
import SwiftUI

final class SpotifyLiteAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Media keys and Now Playing must keep working after the window closes
        // while librespot is still the active SpotifyLite device.
        false
    }
}

@main
struct SpotifyLiteApp: App {
    @NSApplicationDelegateAdaptor(SpotifyLiteAppDelegate.self) private var appDelegate
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
