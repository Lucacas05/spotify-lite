import AppKit
import SwiftUI

/// One-time setup sheet shown when the user wants local playback but
/// librespot is not installed. The app never runs brew itself; the user
/// copies the command, installs, and checks again.
struct LibrespotSetupView: View {
    var player: PlayerStore
    @Environment(\.dismiss) private var dismiss
    @State private var stillMissing = false
    @State private var copied = false

    private static let installCommand = "brew install librespot"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Play music on this Mac", systemImage: "speaker.wave.2.fill")
                .font(.title3.weight(.semibold))

            Text("SpotifyLite can play audio by itself — no official Spotify app needed. It uses librespot, an open-source Spotify Connect player, installed once with Homebrew:")
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(Self.installCommand)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.installCommand, forType: .string)
                    copied = true
                }
            }

            Label {
                Text("Experimental: librespot is an unofficial client, outside Spotify's terms of service (theoretical account risk). Requires Spotify Premium. The first time, Spotify asks for a one-time authorization in your browser.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            if stillMissing {
                Text("librespot was not found yet. Wait for the install to finish, then check again.")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Check again") { checkAgain() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func checkAgain() {
        guard LibrespotLocator.isInstalled else {
            stillMissing = true
            return
        }
        dismiss()
        Task { await player.playOnThisMac() }
    }
}
