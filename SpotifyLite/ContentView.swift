import SwiftUI

struct ContentView: View {
    var auth: AuthManager
    var player: PlayerStore

    var body: some View {
        switch auth.state {
        case .signedIn:
            MainWindow(auth: auth, player: player)
        case .signedOut, .authorizing:
            LoginView(auth: auth)
        }
    }
}
