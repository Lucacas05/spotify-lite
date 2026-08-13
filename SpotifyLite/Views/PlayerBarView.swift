import SwiftUI

struct PlayerBarView: View {
    var player: PlayerStore
    @State private var volume: Double = 50

    var body: some View {
        VStack(spacing: 0) {
            PlaybackScrubber(player: player)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            HStack(alignment: .center, spacing: 16) {
                nowPlayingInfo
                    .frame(maxWidth: .infinity, alignment: .leading)

                transportControls

                HStack(alignment: .center, spacing: 14) {
                    PlayerQueueButton(player: player)
                    PlayerVolumeSlider(player: player, volume: $volume)
                    PlayerDeviceMenu(player: player)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .padding(.top, 6)
        }
        .background(.bar)
        .onChange(of: player.state?.device?.volumePercent) { _, newValue in
            if let newValue { volume = Double(newValue) }
        }
        .task { await player.loadDevices() }
    }

    private var nowPlayingInfo: some View {
        HStack(spacing: 12) {
            PlayerArtwork(url: player.state?.item?.artworkURL, size: 44, corner: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.state?.item?.name ?? "Nothing playing")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(player.state?.item?.artistNames ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var transportControls: some View {
        HStack(spacing: 20) {
            Button { Task { await player.toggleShuffle() } } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(player.isShuffling ? Color.green : Color.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(player.isShuffling ? "Disable shuffle" : "Enable shuffle")

            Button { Task { await player.previous() } } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Previous")

            Button { Task { await player.togglePlayPause() } } label: {
                Image(systemName: (player.state?.isPlaying ?? false) ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.primary))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Play or pause")

            Button { Task { await player.next() } } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Next")
        }
        .fixedSize()
    }
}

private struct PlaybackScrubber: View {
    var player: PlayerStore

    @State private var isScrubbing = false
    @State private var scrubProgressMs = 0.0
    @State private var scrubbingTrackID: String?
    @State private var hovering = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let durationMs = max(player.state?.item?.durationMs ?? 0, 0)
            let live = player.progress(at: context.date)
            let displayed = min(
                max(Int((isScrubbing ? scrubProgressMs : Double(live)).rounded()), 0),
                durationMs
            )
            let fraction: CGFloat = durationMs > 0
                ? CGFloat(displayed) / CGFloat(durationMs)
                : 0

            VStack(spacing: 4) {
                bar(fraction: fraction, durationMs: durationMs, live: live)
                HStack {
                    timeLabel(displayed)
                    Spacer()
                    timeLabel(durationMs)
                }
            }
        }
        .onHover { hovering = $0 }
        .onChange(of: player.currentTrackIdentifier) { _, _ in
            guard isScrubbing else { return }
            isScrubbing = false
            scrubbingTrackID = nil
        }
    }

    private func timeLabel(_ ms: Int) -> some View {
        Text(formatTime(milliseconds: ms))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    private func bar(fraction: CGFloat, durationMs: Int, live: Int) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            let filled = max(0, min(width * fraction, width))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(hovering || isScrubbing ? Color.green : Color.primary.opacity(0.55))
                    .frame(width: max(filled, 3))
                if hovering || isScrubbing, durationMs > 0 {
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 10, height: 10)
                        .offset(x: min(max(filled - 5, 0), width - 10))
                }
            }
            .frame(height: 3)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(dragGesture(width: width, durationMs: durationMs, live: live))
        }
        .frame(height: 14)
        .disabled((player.state?.item?.durationMs ?? 0) <= 0)
        .help("Playback position")
    }

    private func dragGesture(width: CGFloat, durationMs: Int, live: Int) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard durationMs > 0, width > 0 else { return }
                if !isScrubbing {
                    isScrubbing = true
                    scrubbingTrackID = player.currentTrackIdentifier
                    scrubProgressMs = Double(live)
                }
                let x = min(max(value.location.x, 0), width)
                scrubProgressMs = Double(durationMs) * Double(x / width)
            }
            .onEnded { _ in
                guard isScrubbing else { return }
                isScrubbing = false
                let targetMs = Int(scrubProgressMs.rounded())
                let startedTrackID = scrubbingTrackID
                scrubbingTrackID = nil
                guard startedTrackID == player.currentTrackIdentifier else { return }
                Task { await player.seek(to: targetMs, expectedTrackID: startedTrackID) }
            }
    }

    private func formatTime(milliseconds: Int) -> String {
        let seconds = max(milliseconds, 0) / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct PlayerQueueButton: View {
    var player: PlayerStore
    @State private var showingQueue = false

    var body: some View {
        Button { showingQueue.toggle() } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Playback queue")
        .popover(isPresented: $showingQueue, arrowEdge: .bottom) {
            QueueView(player: player)
        }
    }
}

private struct PlayerVolumeSlider: View {
    var player: PlayerStore
    @Binding var volume: Double

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: volumeIcon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 28)
            GeometryReader { geo in
                let filled = geo.size.width * CGFloat(volume / 100)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(Color.primary.opacity(0.5)).frame(width: max(filled, 3))
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 10, height: 10)
                        .offset(x: min(max(filled - 5, 0), geo.size.width - 10))
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let x = min(max(value.location.x, 0), geo.size.width)
                            volume = geo.size.width > 0 ? Double(x / geo.size.width) * 100 : 0
                        }
                        .onEnded { _ in
                            Task { await player.setVolume(Int(volume)) }
                        }
                )
            }
            .frame(width: 96, height: 28)
        }
        .help("Volume")
    }

    private var volumeIcon: String {
        if volume < 1 { return "speaker.slash.fill" }
        if volume < 40 { return "speaker.wave.1.fill" }
        if volume < 75 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

private struct PlayerDeviceMenu: View {
    var player: PlayerStore

    var body: some View {
        Menu {
            Button {
                Task { await player.playOnThisMac() }
            } label: {
                HStack {
                    Text(player.localEngine.status == .starting
                         ? "Starting local player…" : "Play on this Mac")
                    if player.localEngine.isRunning { Image(systemName: "checkmark") }
                }
            }
            .disabled(player.localEngine.status == .starting)
            if player.localEngine.isRunning {
                Button("Stop local player") { player.stopLocalPlayback() }
            }
            Divider()
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
            HStack(spacing: 5) {
                Image(systemName: "hifispeaker")
                    .font(.system(size: 12))
                Text(player.state?.device?.name ?? "Devices")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Output device")
        .onTapGesture { Task { await player.loadDevices() } }
    }
}

private struct PlayerArtwork: View {
    var url: URL?
    var size: CGFloat
    var corner: CGFloat = 6

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Color.secondary.opacity(0.2)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}
