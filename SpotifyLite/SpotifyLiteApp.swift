import SwiftUI

@main
struct SpotifyLiteApp: App {
    init() {
        // Caché de carátulas: 10 MB en memoria, 50 MB en disco.
        URLCache.shared = URLCache(memoryCapacity: 10 * 1024 * 1024,
                                   diskCapacity: 50 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
