import SwiftUI

struct PlayerBarView: View {
    var player: PlayerStore
    @State private var volume: Double = 50

    var body: some View {
        HStack(spacing: 16) {
            // Track actual
            HStack(spacing: 10) {
                AsyncImage(url: player.state?.item?.artworkURL) { image in
                    image.resizable()
                } placeholder: {
                    Color.secondary.opacity(0.2)
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 2) {
                    Text(player.state?.item?.name ?? "Nada sonando")
                        .lineLimit(1)
                    Text(player.state?.item?.artistNames ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 260, alignment: .leading)

            Spacer()

            // Controles
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

            Spacer()

            // Volumen + dispositivo
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                Slider(value: $volume, in: 0...100) { editing in
                    if !editing { Task { await player.setVolume(Int(volume)) } }
                }
                .frame(width: 100)

                Menu {
                    if player.devices.isEmpty {
                        Text("Sin dispositivos activos")
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
                    Button("Actualizar dispositivos") { Task { await player.loadDevices() } }
                } label: {
                    Image(systemName: "hifispeaker")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 40)
                .onTapGesture { Task { await player.loadDevices() } }
            }
            .frame(maxWidth: 220, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .onChange(of: player.state?.device?.volumePercent) { _, newValue in
            if let newValue { volume = Double(newValue) }
        }
        .task { await player.loadDevices() }
    }
}
