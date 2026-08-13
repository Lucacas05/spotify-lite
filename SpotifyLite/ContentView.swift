import SwiftUI

struct ContentView: View {
    var auth: AuthManager
    var player: PlayerStore

    var body: some View {
        switch auth.state {
        case .signedIn:
            MainWindow(auth: auth, player: player)
                .onDisappear {
                    // Closing the window may leave playback in the menu bar,
                    // but logging out must release the local player.
                    if case .signedIn = auth.state { return }
                    player.stopLocalPlayback()
                }
        case .signedOut, .authorizing:
            LoginView(auth: auth)
        }
    }
}
