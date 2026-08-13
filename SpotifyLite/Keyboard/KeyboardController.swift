import Foundation
import AppKit
import Observation
import SwiftUI

private final class WeakNativeView {
    weak var value: NSView?

    init(_ value: NSView) {
        self.value = value
    }
}

@MainActor
@Observable
final class KeyboardController {
    var navigation = NavigationState(zone: .search)

    var sidebarItems: [SidebarItem] = [.search, .likedSongs]
    private(set) var listCount = 0
    @ObservationIgnored private var listTrackAt: ((Int) -> Track?)?
    var playListTrack: ((Track) -> Void)?
    @ObservationIgnored private var nativeViewFocus: AppFocus?
    @ObservationIgnored private var nativeView: WeakNativeView?
    var onSelectSidebarItem: ((SidebarItem) -> Void)?
    var player: PlayerStore?

    var isTyping: Bool {
        (navigation.zone == .search || navigation.commandPaletteOpen) && !navigation.cheatsheetOpen
    }

    var selectedTrack: Track? {
        switch navigation.zone {
        case .list:
            return listTrackAt?(navigation.listIndex)
        case .queue:
            let queue = player?.queue ?? []
            return queue.indices.contains(navigation.queueIndex) ? queue[navigation.queueIndex] : nil
        default:
            return nil
        }
    }

    var focusTarget: AppFocus? {
        if navigation.cheatsheetOpen { return .cheatsheet }
        if navigation.commandPaletteOpen { return .commandPalette }
        switch navigation.zone {
        case .search: return .searchField
        case .sidebar: return .sidebar
        case .list: return .listRow(navigation.listIndex)
        case .queue: return .queueRow(navigation.queueIndex)
        case .player:
            let control = PlayerControl(rawValue: navigation.playerIndex) ?? .playPause
            return .player(control)
        }
    }

    func makeContext() -> NavigationContext {
        NavigationContext(
            sidebarCount: max(sidebarItems.count, 1),
            listCount: listCount,
            queueCount: player?.queue.count ?? 0,
            playerControlCount: PlayerControl.allCases.count,
            searchItemIndices: Set(
                sidebarItems.enumerated().compactMap { index, item in
                    item == .search ? index : nil
                }
            )
        )
    }

    func handle(_ key: NavigationKey) -> Bool {
        if let action = KeyboardRouter.action(for: key, state: navigation) {
            perform(action)
            return true
        }
        return KeyboardRouter.consumesUnmapped(key, state: navigation)
    }

    func handle(press: KeyPress) -> KeyPress.Result {
        handle(NavigationKey(press)) ? .handled : .ignored
    }

    @discardableResult
    func perform(_ action: KeyboardAction) -> NavigationIntent {
        let (next, intent) = NavigationModel.reduce(navigation, action: action, context: makeContext())
        navigation = next
        execute(intent)
        return intent
    }

    func registerList(
        count: Int,
        trackAt: @escaping (Int) -> Track?,
        play: @escaping (Track) -> Void
    ) {
        listCount = count
        listTrackAt = trackAt
        playListTrack = play
        navigation.listIndex = NavigationModel.clamp(navigation.listIndex, count: count)
    }

    func registerNativeView(_ view: NSView, for focus: AppFocus) {
        guard nativeViewFocus != focus || nativeView?.value !== view else { return }
        nativeViewFocus = focus
        nativeView = WeakNativeView(view)
    }

    func registerSidebar(playlists: [SimplifiedPlaylist]) {
        sidebarItems = [.search, .likedSongs] + playlists.map { .playlist($0) }
        navigation.sidebarIndex = NavigationModel.clamp(
            navigation.sidebarIndex,
            count: sidebarItems.count
        )
    }

    func applyNativeFocus(_ focus: AppFocus?) {
        guard let focus, focus != focusTarget else { return }
        switch focus {
        case .searchField:
            navigation.zone = .search
        case .sidebar:
            navigation.zone = .sidebar
        case .listRow(let index):
            navigation.zone = .list
            navigation.listIndex = index
        case .queueRow(let index):
            navigation.zone = .queue
            navigation.queueIndex = index
            navigation.queueOpen = true
        case .player(let control):
            navigation.zone = .player
            navigation.playerIndex = control.rawValue
        case .commandPalette, .cheatsheet:
            break
        }
    }

    func setQueueOpen(_ open: Bool) {
        if open && !navigation.queueOpen {
            perform(.toggleQueue)
        } else if !open && navigation.queueOpen {
            navigation.queueOpen = false
            if navigation.zone == .queue {
                navigation.zone = navigation.zoneBeforeQueue ?? .list
            }
            navigation.zoneBeforeQueue = nil
        }
    }

    func isSelected(zone: FocusZone, index: Int) -> Bool {
        navigation.zone == zone && navigation.index(for: zone) == index
    }

    private func execute(_ intent: NavigationIntent) {
        switch intent {
        case .none:
            break
        case .openSidebarItem(let index):
            guard sidebarItems.indices.contains(index) else { return }
            onSelectSidebarItem?(sidebarItems[index])
            if sidebarItems[index] == .search {
                NotificationCenter.default.post(name: .focusSpotifySearch, object: nil)
            }
        case .playListTrack(let index):
            guard let track = listTrackAt?(index) else { return }
            playListTrack?(track)
        case .togglePlayPause:
            Task { await player?.togglePlayPause() }
        case .seekBySeconds(let seconds):
            Task { await player?.seekBy(seconds: seconds) }
        case .playerPrevious, .previousTrack:
            Task { await player?.previous() }
        case .playerNext, .nextTrack:
            Task { await player?.next() }
        case .toggleShuffle:
            Task { await player?.toggleShuffle() }
        case .adjustVolume(let delta):
            Task { await player?.bumpVolume(delta) }
        case .openDeviceMenu:
            NotificationCenter.default.post(name: .openPlayerDeviceMenu, object: nil)
        case .focusSearchField:
            onSelectSidebarItem?(.search)
            NotificationCenter.default.post(name: .focusSpotifySearch, object: nil)
        case .jumpToSearchResults:
            break
        case .openTrackContextMenu:
            guard nativeViewFocus == focusTarget else { return }
            NativeContextMenu.present(from: nativeView?.value)
        case .addSelectedToQueue:
            guard let track = selectedTrack else { return }
            Task { await player?.playNext(track) }
        case .loadQueue:
            Task { await player?.loadQueue() }
        }
    }
}
