import SwiftUI

struct PlayerBarView: View {
    var player: PlayerStore
    @State private var volume: Double = 50
    @State private var showingQueue = false
    @State private var isScrubbing = false
    @State private var scrubProgressMs = 0.0
    @State private var scrubbingTrackID: String?

    var body: some View {
        HStack(spacing: 16) {
            // Current track
            HStack(spacing: 10) {
                AsyncImage(url: player.state?.item?.artworkURL) { image in
                    image.resizable()
                } placeholder: {
                    Color.secondary.opacity(0.2)
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.state?.item?.name ?? "Nothing playing")
                        .lineLimit(1)
                    Text(player.state?.item?.artistNames ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 260, alignment: .leading)
            .layoutPriority(2)

            Spacer()

            VStack(spacing: 6) {
                // Controls
                HStack(spacing: 20) {
                    Button { Task { await player.previous() } } label: {
                        Image(systemName: "backward.fill")
                    }
                    Button { Task { await player.togglePlayPause() } } label: {
                        Image(systemName: (player.state?.isPlaying ?? false) ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 32))
                    }
                    Button { Task { await player.next() } } label: {
                        Image(systemName: "forward.fill")
                    }
                }
                .buttonStyle(.plain)

                TimelineView(.periodic(from: .now, by: 0.2)) { context in
                    progressSlider(at: context.date)
                }
                .frame(maxWidth: .infinity)
            }
            .frame(minWidth: 180, maxWidth: 420)
            .frame(maxWidth: .infinity)
            .layoutPriority(1)

            Spacer()

            // Volume + device
            HStack(spacing: 12) {
                Button {
                    showingQueue.toggle()
                } label: {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                }
                .buttonStyle(.plain)
                .help("Playback queue")
                .popover(isPresented: $showingQueue, arrowEdge: .bottom) {
                    QueueView(player: player)
                }

                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                Slider(value: $volume, in: 0...100) { editing in
                    if !editing { Task { await player.setVolume(Int(volume)) } }
                }
                .frame(width: 100)

                Menu {
                    if player.devices.isEmpty {
                        Text("No active devices")
                    }
                    ForEach(player.devices) { device in
                        Button {
                            Task { await player.transferPlayback(to: device) }
                        } label: {
                            HStack {
                                Text(device.name)
                                if device.isActive { Image(systemName: "checkmark") }
                            }
                        }
                    }
                    Divider()
                    Button("Refresh devices") { Task { await player.loadDevices() } }
                } label: {
                    Image(systemName: "hifispeaker")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 40)
                .onTapGesture { Task { await player.loadDevices() } }
            }
            .frame(maxWidth: 250, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .onChange(of: player.state?.device?.volumePercent) { _, newValue in
            if let newValue { volume = Double(newValue) }
        }
        .onChange(of: player.currentTrackIdentifier) { _, _ in
            guard isScrubbing else { return }
            // If Spotify changed tracks while dragging, cancel the local scrub.
            isScrubbing = false
            scrubbingTrackID = nil
        }
        .task { await player.loadDevices() }
    }

    private func progressSlider(at date: Date) -> some View {
        let durationMs = max(player.state?.item?.durationMs ?? 0, 0)
        let sliderUpperBound = Double(max(durationMs, 1))
        let liveProgressMs = player.progress(at: date)
        let displayedProgressMs = min(
            max(Int((isScrubbing ? scrubProgressMs : Double(liveProgressMs)).rounded()), 0),
            durationMs
        )

        return VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubProgressMs : Double(liveProgressMs) },
                    set: { newValue in
                        beginScrubIfNeeded()
                        scrubProgressMs = min(max(newValue, 0), Double(durationMs))
                    }
                ),
                in: 0...sliderUpperBound,
                onEditingChanged: handleScrubEditing
            )
            .disabled(durationMs <= 0)
            .frame(minWidth: 160, maxWidth: .infinity)
            .help("Playback position")

            HStack {
                Text(formatTime(milliseconds: displayedProgressMs))
                Spacer()
                Text(formatTime(milliseconds: durationMs))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private func beginScrubIfNeeded() {
        guard !isScrubbing else { return }
        isScrubbing = true
        scrubbingTrackID = player.currentTrackIdentifier
    }

    private func handleScrubEditing(_ isEditing: Bool) {
        if isEditing {
            if !isScrubbing {
                isScrubbing = true
                scrubbingTrackID = player.currentTrackIdentifier
                scrubProgressMs = Double(player.progress())
            }
            return
        }

        isScrubbing = false
        let targetMs = Int(scrubProgressMs.rounded())
        let startedTrackID = scrubbingTrackID
        scrubbingTrackID = nil
        guard startedTrackID == player.currentTrackIdentifier else { return }
        Task { await player.seek(to: targetMs, expectedTrackID: startedTrackID) }
    }

    private func formatTime(milliseconds: Int) -> String {
        let seconds = max(milliseconds, 0) / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
