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
                Link("Crea una app en el Spotify Developer Dashboard",
                     destination: URL(string: "https://developer.spotify.com/dashboard")!)
                    .font(.callout)

                HStack(spacing: 8) {
                    Text(SpotifyAuthConfig.redirectURI)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Button("Copiar URI") { copyRedirectURI() }
                        .buttonStyle(.borderless)
                }
                Text("Registra esa Redirect URI exactamente. No uses localhost ni un Client Secret: el login es PKCE.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 360, alignment: .leading)

                TextField("Client ID de Spotify", text: $auth.clientID)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 320)
                if clientIDLooksOff {
                    Text("Esto no parece un Client ID (32 caracteres hex), pero puedes intentarlo.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if auth.state == .authorizing {
                ProgressView("Esperando a Spotify en el navegador…")
                Button("Cancelar") { auth.cancelLogin() }
            } else {
                Button("Iniciar sesión con Spotify") {
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
