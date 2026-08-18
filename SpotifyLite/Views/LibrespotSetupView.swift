import AppKit
import SwiftUI

/// Consent + setup sheet for opt-in local playback.
///
/// Until this Spotify account consents, it presents the ToS/warning and
/// records that choice. If librespot is missing, it also offers a copyable
/// `brew install librespot` command and "Check again" — never a dead banner
/// with nothing to copy. The app never runs brew itself.
struct LibrespotSetupView: View {
    var player: PlayerStore
    @Environment(\.dismiss) private var dismiss
    @State private var stillMissing = false
    @State private var copied = false
    @State private var binaryInstalled = LibrespotLocator.isInstalled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Play music on this Mac", systemImage: "speaker.wave.2.fill")
                .font(.title3.weight(.semibold))

            Text("SpotifyLite can play audio by itself — no official Spotify app needed. That is optional. Remote devices keep working if you skip this.")
                .fixedSize(horizontal: false, vertical: true)

            Label {
                Text("Experimental: librespot is an unofficial client, outside Spotify's terms of service (theoretical account risk). Requires Spotify Premium. Enabling local playback starts librespot, which asks Spotify for a one-time authorization in your browser.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            if !binaryInstalled {
                Text("librespot is not installed yet. Copy this command, run it in Terminal, then check again:")
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text(LocalPlaybackMenuCopy.brewInstallCommand)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            LocalPlaybackMenuCopy.brewInstallCommand, forType: .string)
                        copied = true
                    }
                }
            }

            if stillMissing {
                Text("librespot was not found yet. Wait for the install to finish, then check again.")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if !player.hasLocalPlaybackConsent {
                    if !binaryInstalled {
                        Button("Check again") { checkAgain() }
                    }
                    Button("Enable on this Mac") { enableLocalPlayback() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else if !binaryInstalled {
                    Button("Check again") { checkAgain() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Play on this Mac") { startAfterConsent() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { binaryInstalled = LibrespotLocator.isInstalled }
    }

    private func enableLocalPlayback() {
        Task { @MainActor in
            guard await player.resolveSpotifyAccount() else { return }
            player.grantLocalPlaybackConsent()
            refreshInstallState()
            guard binaryInstalled else {
                stillMissing = true
                return
            }
            startAfterConsent()
        }
    }

    private func checkAgain() {
        refreshInstallState()
        guard binaryInstalled else {
            stillMissing = true
            return
        }
        stillMissing = false
        guard player.hasLocalPlaybackConsent else { return }
        startAfterConsent()
    }

    private func startAfterConsent() {
        dismiss()
        Task { await player.playOnThisMac() }
    }

    private func refreshInstallState() {
        binaryInstalled = LibrespotLocator.isInstalled
        if binaryInstalled { stillMissing = false }
    }
}
