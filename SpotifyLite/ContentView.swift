import SwiftUI

struct ContentView: View {
    @State private var auth = AuthManager()

    var body: some View {
        switch auth.state {
        case .signedIn:
            MainWindow(auth: auth)
        case .signedOut, .authorizing:
            LoginView(auth: auth)
        }
    }
}
