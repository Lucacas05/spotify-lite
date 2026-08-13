import SwiftUI

struct QueueView: View {
    var player: PlayerStore
    @Environment(KeyboardController.self) private var keyboard

    private var presentation: QueuePresentation { player.queuePresentation }

    var body: some View {
        Group {
            if presentation.showsInitialSpinner {
                ProgressView("Loading queue…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if presentation.showsFailedEmpty {
                ContentUnavailableView(
                    "Could not load the queue",
                    systemImage: "exclamationmark.triangle",
                    description: Text(presentation.error ?? "Try again in a moment."))
            } else if presentation.showsEmptyState {
                ContentUnavailableView(
                    "The queue is empty",
                    systemImage: "text.line.first.and.arrowtriangle.forward",
                    description: Text("Add songs with “Play next.” Spotify controls the order."))
            } else {
                queueList
            }
        }
        .frame(width: 420, height: 440)
        .transaction { $0.animation = nil }
        .onExitCommand { keyboard.perform(.cancel) }
        .onKeyPress(.escape) {
            keyboard.perform(.cancel)
            return .handled
        }
        .safeAreaInset(edge: .top) {
            queueHeader
        }
        .task { await player.loadQueue() }
    }

    private var queueHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Queue")
                    .font(.headline)
                Spacer()
                if presentation.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing queue")
                }
                Button {
                    Task { await player.loadQueue(force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(!presentation.refreshEnabled)
                .help("Refresh queue")
                .accessibilityLabel("Refresh queue")
            }
            Text("Upcoming tracks. Spotify controls the order.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if presentation.showsInlineError, let error = presentation.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.bar)
    }

    private var queueList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(player.queueRows.enumerated()), id: \.element.id) { index, row in
                        HStack(spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .trailing)
                            TrackRow(
                                track: row.track,
                                player: player,
                                showAlbumLink: true,
                                keyboardIndex: index,
                                keyboardZone: .queue,
                                behavior: .queue
                            ) {}
                        }
                        .id(row.id)
                        .accessibilityHint("Upcoming track. Spotify controls the order.")
                        Divider().padding(.leading, 64)
                    }
                }
            }
            .onChange(of: keyboard.navigation.queueIndex) { _, index in
                guard keyboard.navigation.zone == .queue,
                      player.queueRows.indices.contains(index) else { return }
                proxy.scrollTo(player.queueRows[index].id, anchor: .center)
            }
        }
    }
}
