import SwiftUI

struct QueueView: View {
    var player: PlayerStore

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
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(player.queue.enumerated()), id: \.offset) { index, track in
                            HStack(spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, alignment: .trailing)
                                TrackRow(track: track, player: player, showAlbumLink: true) {
                                    Task { await player.play(trackURI: track.uri) }
                                }
                            }
                            Divider().padding(.leading, 64)
                        }
                    }
                }
            }
        }
        .frame(width: 420, height: 440)
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
