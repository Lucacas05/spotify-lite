import AppKit
import SwiftUI

struct LoginView: View {
    @Bindable var auth: AuthManager

    private var clientIDLooksOff: Bool {
        let trimmed = auth.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.wholeMatch(of: /[0-9a-f]{32}/) == nil
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("SpotifyLite")
                .font(.largeTitle.bold())

            VStack(alignment: .leading, spacing: 8) {
                Link("Create an app in the Spotify Developer Dashboard",
                     destination: URL(string: "https://developer.spotify.com/dashboard")!)
                    .font(.callout)

                HStack(spacing: 8) {
                    Text(SpotifyAuthConfig.redirectURI)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copy URI") { copyRedirectURI() }
                        .buttonStyle(.borderless)
                }
                Text("Register that Redirect URI exactly. Do not use localhost or a Client Secret: login is PKCE.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 360, alignment: .leading)

                TextField("Spotify Client ID", text: $auth.clientID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                if clientIDLooksOff {
                    Text("This does not look like a Client ID (32 hex characters), but you can still try it.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if auth.state == .authorizing {
                ProgressView("Waiting for Spotify in the browser…")
                Button("Cancel") { auth.cancelLogin() }
            } else {
                Button("Log in with Spotify") {
                    Task { await auth.login() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }

            if let error = auth.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 380)
            }
        }
        .padding(40)
        .frame(minWidth: 600, minHeight: 400)
    }

    private func copyRedirectURI() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SpotifyAuthConfig.redirectURI, forType: .string)
    }
}
