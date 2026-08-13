import Foundation

enum FocusZone: String, Equatable, Hashable, CaseIterable {
    case search
    case sidebar
    case list
    case queue
    case player
}

enum PlayerControl: Int, Equatable, Hashable, CaseIterable {
    case shuffle
    case previous
    case playPause
    case next
    case queue
    case volume
    case devices
}

struct NavigationContext: Equatable {
    var sidebarCount: Int
    var listCount: Int
    var queueCount: Int
    var playerControlCount: Int
    /// Sidebar rows that open the search field instead of the track list.
    var searchItemIndices: Set<Int> = []

    static let prototype = NavigationContext(
        sidebarCount: 5,
        listCount: 5,
        queueCount: 2,
        playerControlCount: PlayerControl.allCases.count,
        searchItemIndices: []
    )
}

struct NavigationState: Equatable {
    var zone: FocusZone = .list
    var sidebarIndex: Int = 0
    var listIndex: Int = 0
    var queueIndex: Int = 0
    var playerIndex: Int = PlayerControl.playPause.rawValue
    var queueOpen = false
    var cheatsheetOpen = false
    var commandPaletteOpen = false
    var zoneBeforeQueue: FocusZone?
    var zoneBeforePalette: FocusZone?

    func index(for zone: FocusZone) -> Int {
        switch zone {
        case .search: return 0
        case .sidebar: return sidebarIndex
        case .list: return listIndex
        case .queue: return queueIndex
        case .player: return playerIndex
        }
    }

    mutating func setIndex(_ value: Int, for zone: FocusZone) {
        switch zone {
        case .search: break
        case .sidebar: sidebarIndex = value
        case .list: listIndex = value
        case .queue: queueIndex = value
        case .player: playerIndex = value
        }
    }
}

enum NavigationIntent: Equatable {
    case none
    case openSidebarItem(Int)
    case playListTrack(Int)
    case playQueueTrack(Int)
    case togglePlayPause
    case seekBySeconds(Int)
    case playerPrevious
    case playerNext
    case toggleShuffle
    case adjustVolume(Int)
    case openDeviceMenu
    case focusSearchField
    case jumpToSearchResults
    case openTrackContextMenu
    case addSelectedToQueue
    case nextTrack
    case previousTrack
    case loadQueue
}

/// Flat key event. Names match the prototype (`ArrowUp`, `Enter`, ` `).
struct NavigationKey: Equatable {
    var name: String
    var characters: String
    var control: Bool
    var shift: Bool
    var command: Bool
    var option: Bool

    init(
        name: String,
        characters: String? = nil,
        control: Bool = false,
        shift: Bool = false,
        command: Bool = false,
        option: Bool = false
    ) {
        self.name = name
        self.characters = characters ?? name
        self.control = control
        self.shift = shift
        self.command = command
        self.option = option
    }

    var isPrintable: Bool {
        characters.count == 1 && !control && !command && !option
    }

    static func char(
        _ value: String,
        shift: Bool = false,
        control: Bool = false,
        command: Bool = false
    ) -> NavigationKey {
        NavigationKey(
            name: value,
            characters: value,
            control: control,
            shift: shift,
            command: command
        )
    }
}

/// Decides which keys become actions in the current mode (search typing,
/// cheatsheet, palette) without touching the reducer.
enum KeyboardRouter {
    static func action(for key: NavigationKey, state: NavigationState) -> KeyboardAction? {
        if state.cheatsheetOpen {
            if key.name == "Escape" { return .cancel }
            if key.characters == "?" || key.name == "?" { return .toggleCheatsheet }
            return nil
        }

        if state.commandPaletteOpen {
            if key.command, let mapped = KeyMap.action(for: key), mapped == .openCommandPalette {
                return .openCommandPalette
            }
            if key.name == "Escape" { return .cancel }
            return nil
        }

        // Search field: digits and letters type text. Only leave/submit keys
        // (and command shortcuts) are interpreted as actions.
        if state.zone == .search && !key.command && !key.control {
            switch key.name {
            case "Escape": return .cancel
            case "ArrowDown": return .moveDown
            case "Enter": return .activate
            default: return nil
            }
        }

        return KeyMap.action(for: key)
    }

    /// Cheatsheet swallows every key. The palette and search field leave
    /// printable keys for the text field.
    static func consumesUnmapped(_ key: NavigationKey, state: NavigationState) -> Bool {
        state.cheatsheetOpen && !key.command
    }
}

enum NavigationModel {
    static let spatial: [FocusZone: [String: FocusZone]] = [
        .search: ["down": .list],
        .sidebar: ["right": .list, "down": .player, "up": .search],
        .list: ["left": .sidebar, "right": .queue, "down": .player, "up": .search],
        .queue: ["left": .list, "down": .player, "up": .search],
        .player: ["up": .list],
    ]

    static func reduce(
        _ state: NavigationState,
        action: KeyboardAction,
        context: NavigationContext
    ) -> (NavigationState, NavigationIntent) {
        var s = state

        func finish(_ intent: NavigationIntent = .none) -> (NavigationState, NavigationIntent) {
            clampIndices(&s, context: context)
            return (s, intent)
        }

        if s.cheatsheetOpen {
            if action == .cancel || action == .toggleCheatsheet {
                s.cheatsheetOpen = false
            }
            return finish()
        }

        if s.commandPaletteOpen {
            if action == .cancel || action == .openCommandPalette {
                closePalette(&s)
            }
            return finish()
        }

        if s.zone == .search {
            switch action {
            case .cancel:
                s.zone = .list
                return finish()
            case .moveDown, .activate:
                if context.listCount > 0 {
                    s.zone = .list
                    s.listIndex = 0
                    return finish(.jumpToSearchResults)
                }
                return finish()
            case .openCommandPalette:
                openPalette(&s)
                return finish()
            case .focusSearch:
                return finish(.focusSearchField)
            case .toggleCheatsheet:
                return finish()
            default:
                return finish()
            }
        }

        switch action {
        case .toggleCheatsheet:
            s.cheatsheetOpen = true
            return finish()

        case .openCommandPalette:
            openPalette(&s)
            return finish()

        case .focusSidebar:
            return moveToZone(.sidebar, &s, context: context)

        case .focusTrackList:
            return moveToZone(.list, &s, context: context)

        case .toggleQueue:
            return toggleQueue(&s, context: context)

        case .focusPlayer:
            return moveToZone(.player, &s, context: context)

        case .focusSearch:
            s = leaveQueue(s)
            s.zone = .search
            return finish(.focusSearchField)

        case .moveZoneLeft:
            return moveSpatially("left", &s, context: context)
        case .moveZoneRight:
            return moveSpatially("right", &s, context: context)
        case .moveZoneUp:
            return moveSpatially("up", &s, context: context)
        case .moveZoneDown:
            return moveSpatially("down", &s, context: context)

        case .playPause:
            return finish(.togglePlayPause)
        case .nextTrack:
            return finish(.nextTrack)
        case .previousTrack:
            return finish(.previousTrack)
        case .toggleShuffle:
            return finish(.toggleShuffle)
        case .addToQueue:
            return finish(.addSelectedToQueue)
        case .openTrackMenu:
            return finish(.openTrackContextMenu)
        case .volumeUp:
            return finish(.adjustVolume(10))
        case .volumeDown:
            return finish(.adjustVolume(-10))

        case .seekBackward:
            guard s.zone == .player else { return finish() }
            return finish(.seekBySeconds(-10))
        case .seekForward:
            guard s.zone == .player else { return finish() }
            return finish(.seekBySeconds(10))

        case .moveLeft:
            if s.zone == .player {
                s.playerIndex = clamp(s.playerIndex - 1, count: context.playerControlCount)
            }
            return finish()
        case .moveRight:
            if s.zone == .player {
                s.playerIndex = clamp(s.playerIndex + 1, count: context.playerControlCount)
            }
            return finish()
        case .moveUp:
            moveWithinZone(-1, &s, context: context)
            return finish()
        case .moveDown:
            moveWithinZone(1, &s, context: context)
            return finish()

        case .activate:
            return activate(&s, context: context)

        case .cancel:
            if s.queueOpen {
                return closeQueue(&s)
            }
            return finish()

        case .deleteItem:
            return finish()
        }
    }

    private static func activate(
        _ s: inout NavigationState,
        context: NavigationContext
    ) -> (NavigationState, NavigationIntent) {
        switch s.zone {
        case .search:
            if context.listCount > 0 {
                s.zone = .list
                s.listIndex = 0
                return finish(&s, context, .jumpToSearchResults)
            }
            return finish(&s, context)
        case .sidebar:
            if context.searchItemIndices.contains(s.sidebarIndex) {
                s.zone = .search
                return finish(&s, context, .openSidebarItem(s.sidebarIndex))
            }
            s.listIndex = 0
            s.zone = .list
            return finish(&s, context, .openSidebarItem(s.sidebarIndex))
        case .list:
            guard context.listCount > 0 else { return finish(&s, context) }
            return finish(&s, context, .playListTrack(s.listIndex))
        case .queue:
            guard context.queueCount > 0 else { return finish(&s, context) }
            return finish(&s, context, .playQueueTrack(s.queueIndex))
        case .player:
            return activatePlayer(&s, context: context)
        }
    }

    private static func activatePlayer(
        _ s: inout NavigationState,
        context: NavigationContext
    ) -> (NavigationState, NavigationIntent) {
        switch PlayerControl(rawValue: s.playerIndex) {
        case .playPause:
            return finish(&s, context, .togglePlayPause)
        case .previous:
            return finish(&s, context, .playerPrevious)
        case .next:
            return finish(&s, context, .playerNext)
        case .shuffle:
            return finish(&s, context, .toggleShuffle)
        case .volume:
            return finish(&s, context)
        case .queue:
            return toggleQueue(&s, context: context)
        case .devices:
            return finish(&s, context, .openDeviceMenu)
        case nil:
            return finish(&s, context)
        }
    }

    private static func toggleQueue(
        _ s: inout NavigationState,
        context: NavigationContext
    ) -> (NavigationState, NavigationIntent) {
        if s.queueOpen && s.zone == .queue {
            return closeQueue(&s)
        }
        s.zoneBeforeQueue = s.zone == .queue ? s.zoneBeforeQueue : s.zone
        s.queueOpen = true
        s.zone = .queue
        s.queueIndex = clamp(s.queueIndex, count: context.queueCount)
        return finish(&s, context, .loadQueue)
    }

    private static func closeQueue(_ s: inout NavigationState) -> (NavigationState, NavigationIntent) {
        s.queueOpen = false
        s.zone = s.zoneBeforeQueue ?? .list
        s.zoneBeforeQueue = nil
        return (s, .none)
    }

    private static func moveToZone(
        _ zone: FocusZone,
        _ s: inout NavigationState,
        context: NavigationContext
    ) -> (NavigationState, NavigationIntent) {
        if zone == .queue {
            return toggleQueue(&s, context: context)
        }
        s = leaveQueue(s)
        s.zone = zone
        return finish(&s, context, zone == .search ? .focusSearchField : .none)
    }

    private static func moveSpatially(
        _ direction: String,
        _ s: inout NavigationState,
        context: NavigationContext
    ) -> (NavigationState, NavigationIntent) {
        guard let target = spatial[s.zone]?[direction] else {
            return finish(&s, context)
        }
        if target == .queue {
            s.zoneBeforeQueue = s.zone
            s.queueOpen = true
            s.zone = .queue
            return finish(&s, context, .loadQueue)
        }
        s = leaveQueue(s)
        s.zone = target
        return finish(&s, context, target == .search ? .focusSearchField : .none)
    }

    private static func moveWithinZone(
        _ delta: Int,
        _ s: inout NavigationState,
        context: NavigationContext
    ) {
        guard s.zone != .player, s.zone != .search else { return }
        let count = length(s.zone, context)
        s.setIndex(clamp(s.index(for: s.zone) + delta, count: count), for: s.zone)
    }

    private static func leaveQueue(_ s: NavigationState) -> NavigationState {
        var next = s
        if next.zone == .queue || next.queueOpen {
            next.queueOpen = false
            next.zoneBeforeQueue = nil
        }
        return next
    }

    private static func openPalette(_ s: inout NavigationState) {
        s.zoneBeforePalette = s.zone
        s.commandPaletteOpen = true
        s.queueOpen = false
    }

    private static func closePalette(_ s: inout NavigationState) {
        s.commandPaletteOpen = false
        if let previous = s.zoneBeforePalette {
            s.zone = previous
        }
        s.zoneBeforePalette = nil
    }

    private static func length(_ zone: FocusZone, _ context: NavigationContext) -> Int {
        switch zone {
        case .search: return 0
        case .sidebar: return context.sidebarCount
        case .list: return context.listCount
        case .queue: return context.queueCount
        case .player: return context.playerControlCount
        }
    }

    static func clamp(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    private static func clampIndices(_ s: inout NavigationState, context: NavigationContext) {
        s.sidebarIndex = clamp(s.sidebarIndex, count: context.sidebarCount)
        s.listIndex = clamp(s.listIndex, count: context.listCount)
        s.queueIndex = clamp(s.queueIndex, count: context.queueCount)
        s.playerIndex = clamp(s.playerIndex, count: context.playerControlCount)
    }

    private static func finish(
        _ s: inout NavigationState,
        _ context: NavigationContext,
        _ intent: NavigationIntent = .none
    ) -> (NavigationState, NavigationIntent) {
        clampIndices(&s, context: context)
        return (s, intent)
    }
}
