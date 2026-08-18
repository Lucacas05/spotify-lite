import Foundation

/// Named actions the rest of the app binds to. Views and the navigation
/// reducer never mention raw keys — they mention these names.
///
/// To remap shortcuts, edit `KeyMap.bindings` only. Keep the action names
/// stable so views and tests do not change.
enum KeyboardAction: String, CaseIterable, Equatable, Hashable {
    case playPause
    case focusSidebar
    case focusTrackList
    case toggleQueue
    case focusPlayer
    case focusSearch
    case nextTrack
    case previousTrack
    case toggleShuffle
    case addToQueue
    case openTrackMenu
    case volumeUp
    case volumeDown
    case openCommandPalette
    case toggleCheatsheet
    case moveZoneLeft
    case moveZoneRight
    case moveZoneUp
    case moveZoneDown
    case moveUp
    case moveDown
    case moveLeft
    case moveRight
    case seekBackward
    case seekForward
    case activate
    case cancel
    case deleteItem
}

/// One physical chord. `key` uses the same names as the HTML prototype:
/// `"1"`, `"n"`, `" "`, `"ArrowLeft"`, `"Enter"`, `"Escape"`, `"Backspace"`.
struct KeyChord: Hashable, Equatable {
    var key: String
    var control: Bool = false
    var shift: Bool = false
    var command: Bool = false

    var modifierCount: Int {
        (control ? 1 : 0) + (shift ? 1 : 0) + (command ? 1 : 0)
    }
}

/// Central keybinding table. Edit `bindings` to remap shortcuts; do not
/// scatter new key literals across views.
enum KeyMap {
    /// Actions handled on the focused view (arrows, Enter, Esc) rather than
    /// as window-wide key equivalents, so text fields and native controls keep
    /// their default behavior.
    static let focusedViewActions: Set<KeyboardAction> = [
        .moveUp, .moveDown, .moveLeft, .moveRight,
        .activate, .cancel, .deleteItem
    ]

    /// Default chords. The first matching chord wins at lookup time; more
    /// specific modifier combinations are preferred by `action(for:)`.
    static let bindings: [(action: KeyboardAction, chord: KeyChord)] = [
        (.playPause, KeyChord(key: " ")),
        (.focusSidebar, KeyChord(key: "1")),
        (.focusTrackList, KeyChord(key: "2")),
        (.toggleQueue, KeyChord(key: "3")),
        (.focusPlayer, KeyChord(key: "4")),
        (.focusSearch, KeyChord(key: "/")),
        (.focusSearch, KeyChord(key: "f", command: true)),
        (.nextTrack, KeyChord(key: "n")),
        (.previousTrack, KeyChord(key: "p")),
        (.toggleShuffle, KeyChord(key: "s")),
        (.addToQueue, KeyChord(key: "a")),
        (.openTrackMenu, KeyChord(key: "m")),
        (.volumeUp, KeyChord(key: "+")),
        (.volumeUp, KeyChord(key: "=")),
        (.volumeDown, KeyChord(key: "-")),
        (.openCommandPalette, KeyChord(key: "k", command: true)),
        (.toggleCheatsheet, KeyChord(key: "?")),
        (.moveZoneLeft, KeyChord(key: "ArrowLeft", control: true)),
        (.moveZoneRight, KeyChord(key: "ArrowRight", control: true)),
        (.moveZoneUp, KeyChord(key: "ArrowUp", control: true)),
        (.moveZoneDown, KeyChord(key: "ArrowDown", control: true)),
        (.seekBackward, KeyChord(key: "ArrowLeft", shift: true)),
        (.seekForward, KeyChord(key: "ArrowRight", shift: true)),
        (.moveUp, KeyChord(key: "ArrowUp")),
        (.moveDown, KeyChord(key: "ArrowDown")),
        (.moveLeft, KeyChord(key: "ArrowLeft")),
        (.moveRight, KeyChord(key: "ArrowRight")),
        (.activate, KeyChord(key: "Enter")),
        (.cancel, KeyChord(key: "Escape")),
        // Backspace stays bound so the key is consumed, but the action is inert.
        // Queue is a read-only Spotify mirror this version (#12 / map #11 /
        // docs/HANDOFF-queue-reliability.md). Do not build a local queue editor.
        (.deleteItem, KeyChord(key: "Backspace")),
    ]

    static func chords(for action: KeyboardAction) -> [KeyChord] {
        bindings.filter { $0.action == action }.map(\.chord)
    }

    static func action(for key: NavigationKey) -> KeyboardAction? {
        let exact = KeyChord(
            key: key.name,
            control: key.control,
            shift: key.shift,
            command: key.command
        )
        if let action = lookup[exact] { return action }

        if key.isPrintable {
            let byCharacter = KeyChord(
                key: key.characters,
                control: key.control,
                shift: false,
                command: key.command
            )
            if let action = lookup[byCharacter] { return action }

            let lowered = KeyChord(key: key.characters.lowercased())
            if !key.shift, !key.control, !key.command, let action = lookup[lowered] {
                return action
            }
        }

        // Prefer the most specific remaining match (e.g. Shift+Left vs Left).
        let candidates = lookup.keys.filter {
            $0.key == key.name
                && $0.control == key.control
                && $0.command == key.command
                && $0.shift == key.shift
        }
        return candidates.max(by: { $0.modifierCount < $1.modifierCount }).flatMap { lookup[$0] }
    }

    private static let lookup: [KeyChord: KeyboardAction] = {
        var map: [KeyChord: KeyboardAction] = [:]
        for pair in bindings {
            if map[pair.chord] == nil {
                map[pair.chord] = pair.action
            }
        }
        return map
    }()
}

extension KeyboardAction {
    var title: String {
        switch self {
        case .playPause: return "Play / Pause"
        case .focusSidebar: return "Focus sidebar"
        case .focusTrackList: return "Focus track list"
        case .toggleQueue: return "Toggle queue"
        case .focusPlayer: return "Focus player"
        case .focusSearch: return "Search"
        case .nextTrack: return "Next track"
        case .previousTrack: return "Previous track"
        case .toggleShuffle: return "Toggle shuffle"
        case .addToQueue: return "Add to queue"
        case .openTrackMenu: return "Track menu"
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .openCommandPalette: return "Command palette"
        case .toggleCheatsheet: return "Keyboard shortcuts"
        case .moveZoneLeft: return "Zone left"
        case .moveZoneRight: return "Zone right"
        case .moveZoneUp: return "Zone up"
        case .moveZoneDown: return "Zone down"
        case .moveUp: return "Move up"
        case .moveDown: return "Move down"
        case .moveLeft: return "Move left"
        case .moveRight: return "Move right"
        case .seekBackward: return "Seek backward 10s"
        case .seekForward: return "Seek forward 10s"
        case .activate: return "Activate"
        case .cancel: return "Cancel"
        case .deleteItem: return "Remove from queue"
        }
    }

    var cheatsheetGroup: String {
        switch self {
        case .focusSidebar, .focusTrackList, .toggleQueue, .focusPlayer, .focusSearch,
             .moveZoneLeft, .moveZoneRight, .moveZoneUp, .moveZoneDown:
            return "Zones"
        case .moveUp, .moveDown, .moveLeft, .moveRight, .activate, .cancel, .deleteItem:
            return "Inside a zone"
        case .playPause, .nextTrack, .previousTrack, .toggleShuffle, .volumeUp, .volumeDown,
             .seekBackward, .seekForward:
            return "Playback"
        case .addToQueue, .openTrackMenu:
            return "Track"
        case .openCommandPalette, .toggleCheatsheet:
            return "Palettes"
        }
    }
}

extension KeyChord {
    var displayLabel: String {
        var parts: [String] = []
        if command { parts.append("⌘") }
        if control { parts.append("⌃") }
        if shift { parts.append("⇧") }
        parts.append(Self.symbol(for: key))
        return parts.joined()
    }

    private static func symbol(for key: String) -> String {
        switch key {
        case " ": return "Space"
        case "ArrowUp": return "↑"
        case "ArrowDown": return "↓"
        case "ArrowLeft": return "←"
        case "ArrowRight": return "→"
        case "Enter": return "Enter"
        case "Escape": return "Esc"
        case "Backspace": return "⌫"
        default: return key.uppercased()
        }
    }
}
