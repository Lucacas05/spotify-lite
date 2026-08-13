import SwiftUI

struct QueueView: View {
    var player: PlayerStore

    var body: some View {
        Group {
            if player.queueIsLoading && player.queue.isEmpty {
                ProgressView("Cargando cola…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if player.queue.isEmpty {
                ContentUnavailableView(
                    "La cola está vacía",
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    description: Text("Añade canciones con “Reproducir siguiente”."))
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
                Text("Cola")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await player.loadQueue() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Actualizar cola")
            }
            .padding(12)
            .background(.bar)
        }
        .task { await player.loadQueue() }
    }
}
