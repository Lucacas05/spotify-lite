import SwiftUI

struct ContentView: View {
    var auth: AuthManager
    var player: PlayerStore

    var body: some View {
        switch auth.state {
        case .signedIn:
            MainWindow(auth: auth, player: player)
                .task {
                    // Warm up the local Connect device so the first play
                    // doesn't have to wait for librespot to register.
                    await player.localEngine.start()
                }
        case .signedOut, .authorizing:
            LoginView(auth: auth)
        }
    }
}
