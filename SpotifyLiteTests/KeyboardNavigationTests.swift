import XCTest
@testable import SpotifyLite

final class KeyboardNavigationTests: XCTestCase {
    private let context = NavigationContext.prototype

    func testDirectZoneJumps() {
        var state = NavigationState()
        apply(.char("1"), to: &state)
        XCTAssertEqual(state.zone, .sidebar)
        apply(.char("2"), to: &state)
        XCTAssertEqual(state.zone, .list)
        apply(.char("4"), to: &state)
        XCTAssertEqual(state.zone, .player)
        apply(.char("/"), to: &state)
        XCTAssertEqual(state.zone, .search)
    }

    func testThreeTogglesQueuePopoverAndRestoresFocus() {
        var state = NavigationState()
        state.zone = .list
        _ = apply(.char("3"), to: &state)
        XCTAssertTrue(state.queueOpen)
        XCTAssertEqual(state.zone, .queue)

        _ = apply(.char("3"), to: &state)
        XCTAssertFalse(state.queueOpen)
        XCTAssertEqual(state.zone, .list)
    }

    func testDigitsTypeInSearchInsteadOfSwitchingZones() {
        var state = NavigationState(zone: .search)
        XCTAssertNil(KeyboardRouter.action(for: .char("1"), state: state))
        XCTAssertNil(KeyboardRouter.action(for: .char("4"), state: state))
        XCTAssertNil(KeyboardRouter.action(for: .char("n"), state: state))
        XCTAssertNil(KeyboardRouter.action(for: .char(" "), state: state))
        apply(.char("1"), to: &state)
        XCTAssertEqual(state.zone, .search)
    }

    func testSearchEscapeReturnsToList() {
        var state = NavigationState(zone: .search)
        _ = apply(NavigationKey(name: "Escape"), to: &state)
        XCTAssertEqual(state.zone, .list)
    }

    func testSearchDownJumpsToResultsWhenPresent() {
        var state = NavigationState(zone: .search)
        let intent = apply(NavigationKey(name: "ArrowDown"), to: &state)
        XCTAssertEqual(state.zone, .list)
        XCTAssertEqual(state.listIndex, 0)
        XCTAssertEqual(intent, .jumpToSearchResults)
    }

    func testSearchDownDoesNothingWithoutResults() {
        var state = NavigationState(zone: .search)
        let empty = NavigationContext(
            sidebarCount: 5, listCount: 0, queueCount: 0,
            playerControlCount: PlayerControl.allCases.count
        )
        let intent = apply(NavigationKey(name: "ArrowDown"), to: &state, context: empty)
        XCTAssertEqual(state.zone, .search)
        XCTAssertEqual(intent, .none)
    }

    func testOpeningPlaylistJumpsFocusToTrackList() {
        var state = NavigationState(zone: .sidebar)
        state.sidebarIndex = 2
        let intent = apply(NavigationKey(name: "Enter"), to: &state)
        XCTAssertEqual(state.zone, .list)
        XCTAssertEqual(state.listIndex, 0)
        XCTAssertEqual(intent, .openSidebarItem(2))
    }

    func testOpeningSearchSidebarItemFocusesSearchField() {
        var state = NavigationState(zone: .sidebar)
        let appContext = NavigationContext(
            sidebarCount: 4, listCount: 0, queueCount: 0,
            playerControlCount: PlayerControl.allCases.count,
            searchItemIndices: [0]
        )
        let intent = apply(NavigationKey(name: "Enter"), to: &state, context: appContext)
        XCTAssertEqual(state.zone, .search)
        XCTAssertEqual(intent, .openSidebarItem(0))
    }

    func testEnterOnTrackRowPlaysThatIndex() {
        var state = NavigationState(zone: .list)
        state.listIndex = 2
        XCTAssertEqual(apply(NavigationKey(name: "Enter"), to: &state), .playListTrack(2))
    }

    func testEnterOnEmptyListIsANoOp() {
        var state = NavigationState(zone: .list)
        let empty = NavigationContext(
            sidebarCount: 2, listCount: 0, queueCount: 0,
            playerControlCount: PlayerControl.allCases.count
        )
        XCTAssertEqual(apply(NavigationKey(name: "Enter"), to: &state, context: empty), .none)
    }

    func testArrowsMoveWithinSidebarAndClamp() {
        var state = NavigationState(zone: .sidebar)
        _ = apply(NavigationKey(name: "ArrowDown"), to: &state)
        _ = apply(NavigationKey(name: "ArrowDown"), to: &state)
        XCTAssertEqual(state.sidebarIndex, 2)
        for _ in 0..<10 { _ = apply(NavigationKey(name: "ArrowDown"), to: &state) }
        XCTAssertEqual(state.sidebarIndex, 4)
        for _ in 0..<10 { _ = apply(NavigationKey(name: "ArrowUp"), to: &state) }
        XCTAssertEqual(state.sidebarIndex, 0)
    }

    func testSpatialControlArrowsMoveBetweenZones() {
        var state = NavigationState(zone: .list)
        _ = apply(NavigationKey(name: "ArrowLeft", control: true), to: &state)
        XCTAssertEqual(state.zone, .sidebar)
        _ = apply(NavigationKey(name: "ArrowRight", control: true), to: &state)
        XCTAssertEqual(state.zone, .list)
        _ = apply(NavigationKey(name: "ArrowRight", control: true), to: &state)
        XCTAssertEqual(state.zone, .queue)
        XCTAssertTrue(state.queueOpen)
        _ = apply(NavigationKey(name: "ArrowDown", control: true), to: &state)
        XCTAssertEqual(state.zone, .player)
        XCTAssertFalse(state.queueOpen)
        _ = apply(NavigationKey(name: "ArrowUp", control: true), to: &state)
        XCTAssertEqual(state.zone, .list)
    }

    func testSpaceTogglesPlaybackOutsideSearch() {
        var state = NavigationState(zone: .list)
        XCTAssertEqual(apply(.char(" "), to: &state), .togglePlayPause)
    }

    func testPlayerArrowsMoveControlFocusAndShiftSeeks() {
        var state = NavigationState(zone: .player)
        state.playerIndex = PlayerControl.playPause.rawValue
        _ = apply(NavigationKey(name: "ArrowRight"), to: &state)
        XCTAssertEqual(state.playerIndex, PlayerControl.next.rawValue)
        XCTAssertEqual(
            apply(NavigationKey(name: "ArrowRight", shift: true), to: &state),
            .seekBySeconds(10)
        )
        XCTAssertEqual(
            apply(NavigationKey(name: "ArrowLeft", shift: true), to: &state),
            .seekBySeconds(-10)
        )
        XCTAssertEqual(apply(NavigationKey(name: "Enter"), to: &state), .playerNext)
    }

    func testShiftArrowsDoNotSeekOutsidePlayer() {
        var state = NavigationState(zone: .list)
        XCTAssertEqual(
            apply(NavigationKey(name: "ArrowRight", shift: true), to: &state),
            .none
        )
    }

    func testCheatsheetIsModalUntilEscapeOrQuestionMark() {
        var state = NavigationState(zone: .list)
        _ = apply(.char("?"), to: &state)
        XCTAssertTrue(state.cheatsheetOpen)
        XCTAssertEqual(apply(.char("n"), to: &state), .none)
        XCTAssertTrue(state.cheatsheetOpen)
        _ = apply(.char("?"), to: &state)
        XCTAssertFalse(state.cheatsheetOpen)

        _ = apply(.char("?"), to: &state)
        _ = apply(NavigationKey(name: "Escape"), to: &state)
        XCTAssertFalse(state.cheatsheetOpen)
    }

    func testQuestionMarkInSearchIsNotAShortcut() {
        let state = NavigationState(zone: .search)
        XCTAssertNil(KeyboardRouter.action(for: .char("?"), state: state))
    }

    func testEmptyQueueActivateAndEscape() {
        var state = NavigationState(zone: .list)
        let emptyQueue = NavigationContext(
            sidebarCount: 3, listCount: 4, queueCount: 0,
            playerControlCount: PlayerControl.allCases.count
        )
        _ = apply(.char("3"), to: &state, context: emptyQueue)
        XCTAssertEqual(state.zone, .queue)
        XCTAssertEqual(apply(NavigationKey(name: "Enter"), to: &state, context: emptyQueue), .none)
        _ = apply(NavigationKey(name: "Escape"), to: &state, context: emptyQueue)
        XCTAssertEqual(state.zone, .list)
        XCTAssertFalse(state.queueOpen)
    }

    func testSingleLetterShortcutsMapThroughKeyMap() {
        XCTAssertEqual(KeyMap.action(for: .char("n")), .nextTrack)
        XCTAssertEqual(KeyMap.action(for: .char("p")), .previousTrack)
        XCTAssertEqual(KeyMap.action(for: .char("s")), .toggleShuffle)
        XCTAssertEqual(KeyMap.action(for: .char("a")), .addToQueue)
        XCTAssertEqual(KeyMap.action(for: .char("m")), .openTrackMenu)
        XCTAssertEqual(KeyMap.action(for: .char("+")), .volumeUp)
        XCTAssertEqual(KeyMap.action(for: .char("-")), .volumeDown)
        XCTAssertEqual(KeyMap.action(for: .char("=")), .volumeUp)
    }

    func testLetterShortcutsFireOutsideSearch() {
        var state = NavigationState(zone: .list)
        XCTAssertEqual(apply(.char("n"), to: &state), .nextTrack)
        XCTAssertEqual(apply(.char("a"), to: &state), .addSelectedToQueue)
        XCTAssertEqual(apply(.char("m"), to: &state), .openTrackContextMenu)
        XCTAssertEqual(apply(.char("+"), to: &state), .adjustVolume(10))
    }

    func testCommandPaletteToggleRestoresZone() {
        var state = NavigationState(zone: .sidebar)
        _ = apply(NavigationKey(name: "k", characters: "k", command: true), to: &state)
        XCTAssertTrue(state.commandPaletteOpen)
        _ = apply(NavigationKey(name: "Escape"), to: &state)
        XCTAssertFalse(state.commandPaletteOpen)
        XCTAssertEqual(state.zone, .sidebar)
    }

    func testLegacyCommandNumberShortcutsAreRemoved() {
        XCTAssertNil(KeyMap.action(for: NavigationKey(name: "1", characters: "1", command: true)))
        XCTAssertNil(KeyMap.action(for: NavigationKey(name: "2", characters: "2", command: true)))
        XCTAssertEqual(
            KeyMap.action(for: NavigationKey(name: "f", characters: "f", command: true)),
            .focusSearch
        )
        XCTAssertEqual(KeyMap.action(for: .char(" ")), .playPause)
    }

    func testCommandKAlwaysOpensPalette() {
        XCTAssertEqual(
            KeyMap.action(for: NavigationKey(name: "k", characters: "k", command: true)),
            .openCommandPalette
        )
    }

    func testControlArrowPrefersZoneMoveOverInZoneMove() {
        XCTAssertEqual(
            KeyMap.action(for: NavigationKey(name: "ArrowLeft", control: true)),
            .moveZoneLeft
        )
        XCTAssertEqual(
            KeyMap.action(for: NavigationKey(name: "ArrowLeft")),
            .moveLeft
        )
        XCTAssertEqual(
            KeyMap.action(for: NavigationKey(name: "ArrowLeft", shift: true)),
            .seekBackward
        )
    }

    func testQueueEscapeRestoresPreviousZone() {
        var state = NavigationState(zone: .player)
        _ = apply(.char("3"), to: &state)
        XCTAssertEqual(state.zone, .queue)
        _ = apply(NavigationKey(name: "Escape"), to: &state)
        XCTAssertEqual(state.zone, .player)
        XCTAssertFalse(state.queueOpen)
    }

    func testEnterOnQueueInspectsWithoutStartingPlayback() {
        var state = NavigationState(zone: .queue)
        state.queueOpen = true
        state.queueIndex = 1
        XCTAssertEqual(apply(NavigationKey(name: "Enter"), to: &state), .none)
        XCTAssertEqual(state.zone, .queue)
        XCTAssertEqual(state.queueIndex, 1)
    }

    func testPrototypeBasicFlow() {
        var state = NavigationState()
        _ = apply(.char("1"), to: &state)
        XCTAssertEqual(state.zone, .sidebar)
        _ = apply(NavigationKey(name: "ArrowDown"), to: &state)
        _ = apply(NavigationKey(name: "ArrowDown"), to: &state)
        XCTAssertEqual(state.sidebarIndex, 2)
        _ = apply(NavigationKey(name: "Enter"), to: &state)
        XCTAssertEqual(state.zone, .list)
        _ = apply(NavigationKey(name: "ArrowDown"), to: &state)
        XCTAssertEqual(state.listIndex, 1)
        XCTAssertEqual(apply(NavigationKey(name: "Enter"), to: &state), .playListTrack(1))
        XCTAssertEqual(apply(.char(" "), to: &state), .togglePlayPause)
    }

    // MARK: - Helpers

    @discardableResult
    private func apply(
        _ key: NavigationKey,
        to state: inout NavigationState,
        context: NavigationContext? = nil
    ) -> NavigationIntent {
        let context = context ?? self.context
        guard let action = KeyboardRouter.action(for: key, state: state) else {
            return .none
        }
        let intent: NavigationIntent
        (state, intent) = NavigationModel.reduce(state, action: action, context: context)
        return intent
    }
}
