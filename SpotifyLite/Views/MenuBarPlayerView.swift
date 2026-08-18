import AppKit
import SwiftUI

struct MenuBarPlayerView: View {
    var auth: AuthManager
    var player: PlayerStore
    @AppStorage("menuBarEnabled") private var menuBarEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if auth.state == .signedIn {
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.state?.item?.name ?? "Nothing playing")
                        .font(.headline)
                        .lineLimit(1)
                    Text(player.state?.item?.artistNames ?? "SpotifyLite")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack {
                    Button { Task { await player.previous() } } label: {
                        Image(systemName: "backward.fill")
                    }
                    Button { Task { await player.togglePlayPause() } } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    }
                    Button { Task { await player.next() } } label: {
                        Image(systemName: "forward.fill")
                    }
                }
                Button("Hide menu bar icon") { menuBarEnabled = false }
                Divider()
                Button("Log out") { auth.logout() }
            } else {
                Text("Open SpotifyLite to log in.")
                    .foregroundStyle(.secondary)
                Button("Hide menu bar icon") { menuBarEnabled = false }
            }
            Divider()
            Button("Quit SpotifyLite") { NSApplication.shared.terminate(nil) }
        }
        .padding(4)
        .frame(width: 260)
    }
}
