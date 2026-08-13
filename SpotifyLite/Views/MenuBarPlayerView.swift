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
                    Text(player.state?.item?.name ?? "Nada sonando")
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
                        Image(systemName: (player.state?.isPlaying ?? false) ? "pause.fill" : "play.fill")
                    }
                    Button { Task { await player.next() } } label: {
                        Image(systemName: "forward.fill")
                    }
                }
                Button("Ocultar icono de la barra de menús") { menuBarEnabled = false }
                Divider()
                Button("Cerrar sesión") { auth.logout() }
            } else {
                Text("Abre SpotifyLite para iniciar sesión.")
                    .foregroundStyle(.secondary)
                Button("Ocultar icono de la barra de menús") { menuBarEnabled = false }
            }
            Divider()
            Button("Salir de SpotifyLite") { NSApplication.shared.terminate(nil) }
        }
        .padding(4)
        .frame(width: 260)
    }
}
