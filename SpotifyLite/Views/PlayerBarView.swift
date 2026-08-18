import SwiftUI
import AppKit

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
        .onChange(of: player.volumePercent) { _, newValue in
            volume = Double(newValue)
        }
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
            .keyboardNavigable(focus: .player(.shuffle), handleActivate: false)

            Button { Task { await player.previous() } } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Previous")
            .keyboardNavigable(focus: .player(.previous), handleActivate: false)

            Button { Task { await player.togglePlayPause() } } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.primary))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Play or pause")
            .keyboardNavigable(focus: .player(.playPause), handleActivate: false)

            Button { Task { await player.next() } } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Next")
            .keyboardNavigable(focus: .player(.next), handleActivate: false)
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

    private var usesTimedScrubber: Bool {
        PlaybackScrubberTimeline.usesTimedScrubber(
            isPlaying: player.isPlaying,
            durationMs: player.state?.item?.durationMs ?? 0,
            isScrubbing: isScrubbing
        )
    }

    var body: some View {
        let durationMs = max(player.state?.item?.durationMs ?? 0, 0)
        VStack(spacing: 4) {
            bar(durationMs: durationMs)
            timeRow(durationMs: durationMs)
        }
        .onHover { hovering = $0 }
        .onChange(of: player.currentTrackIdentifier) { _, _ in
            guard isScrubbing else { return }
            isScrubbing = false
            scrubbingTrackID = nil
        }
    }

    private func timeRow(durationMs: Int) -> some View {
        HStack {
            timedDate { date in
                timeLabel(displayedProgress(at: date, durationMs: durationMs))
            }
            Spacer()
            timeLabel(durationMs)
        }
    }

    private func timeLabel(_ ms: Int) -> some View {
        Text(formatTime(milliseconds: ms))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
    }

    private func bar(durationMs: Int) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                timedDate { date in
                    fill(at: date, width: width, durationMs: durationMs)
                }
            }
            .frame(height: 3)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(dragGesture(width: width, durationMs: durationMs))
        }
        .frame(height: 14)
        .disabled(durationMs <= 0)
        .help("Playback position")
    }

    @ViewBuilder
    private func timedDate<Content: View>(@ViewBuilder content: @escaping (Date) -> Content) -> some View {
        if usesTimedScrubber {
            TimelineView(.periodic(from: .now, by: PlaybackScrubberTimeline.tickSeconds)) { context in
                content(context.date)
            }
        } else {
            content(.now)
        }
    }

    private func fill(at date: Date, width: CGFloat, durationMs: Int) -> some View {
        let displayed = displayedProgress(at: date, durationMs: durationMs)
        let fraction: CGFloat = durationMs > 0 ? CGFloat(displayed) / CGFloat(durationMs) : 0
        let filled = max(0, min(width * fraction, width))
        return ZStack(alignment: .leading) {
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
    }

    private func displayedProgress(at date: Date, durationMs: Int) -> Int {
        let live = player.progress(at: date)
        return min(
            max(Int((isScrubbing ? scrubProgressMs : Double(live)).rounded()), 0),
            durationMs
        )
    }

    private func dragGesture(width: CGFloat, durationMs: Int) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard durationMs > 0, width > 0 else { return }
                if !isScrubbing {
                    isScrubbing = true
                    scrubbingTrackID = player.currentTrackIdentifier
                    scrubProgressMs = Double(player.progress(at: .now))
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
    @Environment(KeyboardController.self) private var keyboard

    var body: some View {
        Button { keyboard.setQueueOpen(!keyboard.navigation.queueOpen) } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Playback queue")
        .keyboardNavigable(focus: .player(.queue), handleActivate: false)
        .popover(isPresented: queuePresented, arrowEdge: .bottom) {
            QueueView(player: player)
        }
    }

    private var queuePresented: Binding<Bool> {
        Binding(
            get: { keyboard.navigation.queueOpen },
            set: { keyboard.setQueueOpen($0) }
        )
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
        .keyboardNavigable(focus: .player(.volume), handleActivate: false)
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
    @State private var hostView: NSView?

    var body: some View {
        Menu {
            deviceMenuItems
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
        .keyboardNavigable(focus: .player(.devices), handleActivate: false)
        .background(NSViewCapture { hostView = $0 })
        .onTapGesture { Task { await player.loadDevices() } }
        .onReceive(NotificationCenter.default.publisher(for: .openPlayerDeviceMenu)) { _ in
            presentDeviceMenu()
        }
        .onKeyPress(.return) {
            presentDeviceMenu()
            return .handled
        }
    }

    @ViewBuilder
    private var deviceMenuItems: some View {
        Button {
            Task { await player.playOnThisMac() }
        } label: {
            HStack {
                Text(player.localPlaybackMenuTitle)
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
    }

    private func presentDeviceMenu() {
        let menu = NSMenu()
        let playLocal = NSMenuItem(
            title: player.localPlaybackMenuTitle,
            action: #selector(DeviceMenuTarget.playOnThisMac),
            keyEquivalent: ""
        )
        playLocal.isEnabled = player.localEngine.status != .starting
        menu.addItem(playLocal)
        if player.localEngine.isRunning {
            menu.addItem(NSMenuItem(
                title: "Stop local player",
                action: #selector(DeviceMenuTarget.stopLocal),
                keyEquivalent: ""
            ))
        }
        menu.addItem(.separator())
        if player.devices.isEmpty {
            let empty = NSMenuItem(title: "No active devices", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for (index, device) in player.devices.enumerated() {
            let title = device.isActive ? "✓ \(device.name)" : device.name
            let item = NSMenuItem(
                title: title,
                action: #selector(DeviceMenuTarget.transfer(_:)),
                keyEquivalent: ""
            )
            item.tag = index
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Refresh devices",
            action: #selector(DeviceMenuTarget.refresh),
            keyEquivalent: ""
        ))
        let target = DeviceMenuTarget(player: player)
        for item in menu.items where item.action != nil {
            item.target = target
        }
        objc_setAssociatedObject(menu, &deviceMenuTargetKey, target, .OBJC_ASSOCIATION_RETAIN)
        if let hostView {
            let point = NSPoint(x: 0, y: hostView.bounds.height)
            menu.popUp(positioning: nil, at: point, in: hostView)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}

private var deviceMenuTargetKey: UInt8 = 0

private final class DeviceMenuTarget: NSObject {
    let player: PlayerStore
    init(player: PlayerStore) { self.player = player }

    @objc func playOnThisMac() {
        Task { @MainActor in await player.playOnThisMac() }
    }

    @objc func stopLocal() {
        Task { @MainActor in player.stopLocalPlayback() }
    }

    @objc func transfer(_ sender: NSMenuItem) {
        let index = sender.tag
        Task { @MainActor in
            guard player.devices.indices.contains(index) else { return }
            await player.transferPlayback(to: player.devices[index])
        }
    }

    @objc func refresh() {
        Task { @MainActor in await player.loadDevices() }
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
