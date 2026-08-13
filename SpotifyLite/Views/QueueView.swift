import SwiftUI

struct QueueView: View {
    var player: PlayerStore
    @Environment(KeyboardController.self) private var keyboard

    var body: some View {
        Group {
            if player.queueIsLoading && player.queue.isEmpty {
                ProgressView("Loading queue…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if player.queue.isEmpty {
                ContentUnavailableView(
                    "The queue is empty",
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    description: Text("Add songs with “Play next”."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(player.queue.enumerated()), id: \.offset) { index, track in
                                HStack(spacing: 10) {
                                    Text("\(index + 1)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 24, alignment: .trailing)
                                    TrackRow(
                                        track: track,
                                        player: player,
                                        showAlbumLink: true,
                                        keyboardIndex: index,
                                        keyboardZone: .queue
                                    ) {
                                        Task { await player.play(trackURI: track.uri) }
                                    }
                                }
                                .id(index)
                                Divider().padding(.leading, 64)
                            }
                        }
                    }
                    .onChange(of: keyboard.navigation.queueIndex) { _, index in
                        if keyboard.navigation.zone == .queue {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 420, height: 440)
        .onExitCommand { keyboard.perform(.cancel) }
        .onKeyPress(.escape) {
            keyboard.perform(.cancel)
            return .handled
        }
        .safeAreaInset(edge: .top) {
            HStack {
                Text("Queue")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await player.loadQueue() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh queue")
            }
            .padding(12)
            .background(.bar)
        }
        .task { await player.loadQueue() }
    }
}
