import SwiftUI

struct MainWindow: View {
    var auth: AuthManager
    @State private var profile: UserProfile?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            if let profile {
                Image(systemName: "person.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("Hola, \(profile.displayName ?? profile.id)")
                    .font(.title)
                if profile.product != "premium" {
                    Text("Cuenta sin Premium: el playback local no estará disponible, pero el control remoto sí.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 400)
                }
            } else if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 400)
                Button("Reintentar") { Task { await loadProfile() } }
            } else {
                ProgressView("Cargando perfil…")
            }

            Button("Cerrar sesión") { auth.logout() }
                .padding(.top, 24)
        }
        .padding(40)
        .frame(minWidth: 600, minHeight: 400)
        .task { await loadProfile() }
    }

    private func loadProfile() async {
        error = nil
        do {
            profile = try await SpotifyClient.shared.request("me")
        } catch {
            self.error = error.localizedDescription
        }
    }
}
