import SwiftUI

struct CheatsheetView: View {
    var keyboard: KeyboardController
    @Environment(\.appFocus) private var appFocus

    private let groups = ["Zones", "Inside a zone", "Playback", "Track", "Palettes"]

    var body: some View {
        ZStack {
            Color.black.opacity(0.65)
                .ignoresSafeArea()
                .onTapGesture { keyboard.perform(.cancel) }

            VStack(alignment: .leading, spacing: 16) {
                Text("Keyboard shortcuts")
                    .font(.title2.bold())

                ForEach(groups, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(rows(in: group), id: \.action) { row in
                            HStack(alignment: .firstTextBaseline) {
                                HStack(spacing: 4) {
                                    ForEach(row.chords, id: \.displayLabel) { chord in
                                        Text(chord.displayLabel)
                                            .font(.system(.caption, design: .monospaced))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                                    }
                                }
                                .frame(width: 140, alignment: .leading)
                                Text(row.action.title)
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }
                }

                Text("Press Esc or ? to close. Shortcuts are defined in KeyMap.swift.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(24)
            .frame(minWidth: 420)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .keyboardNavigable(focus: .cheatsheet, handleActivate: false, handleArrows: false)
        }
        .onKeyPress {
            keyboard.handle(press: $0)
        }
    }

    private func rows(in group: String) -> [(action: KeyboardAction, chords: [KeyChord])] {
        var seen = Set<KeyboardAction>()
        var result: [(KeyboardAction, [KeyChord])] = []
        for pair in KeyMap.bindings {
            guard pair.action.cheatsheetGroup == group else { continue }
            // Hidden on purpose: Backspace "Remove from queue" is inert (#12 /
            // map #11 / docs/HANDOFF-queue-reliability.md).
            guard pair.action != .deleteItem else { continue }
            guard seen.insert(pair.action).inserted else { continue }
            let chords = KeyMap.chords(for: pair.action).filter { $0.key != "=" }
            result.append((pair.action, chords))
        }
        return result
    }
}
