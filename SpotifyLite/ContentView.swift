import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note")
                .font(.system(size: 48))
            Text("SpotifyLite")
                .font(.title)
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}
