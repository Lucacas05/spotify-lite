import Foundation
import AppKit
import SwiftUI

enum AppFocus: Hashable {
    case searchField
    case sidebar
    case listRow(Int)
    case queueRow(Int)
    case player(PlayerControl)
    case commandPalette
    case cheatsheet
}

private struct AppFocusBindingKey: EnvironmentKey {
    static let defaultValue: FocusState<AppFocus?>.Binding? = nil
}

extension EnvironmentValues {
    var appFocus: FocusState<AppFocus?>.Binding? {
        get { self[AppFocusBindingKey.self] }
        set { self[AppFocusBindingKey.self] = newValue }
    }
}

extension Notification.Name {
    static let openPlayerDeviceMenu = Notification.Name("openPlayerDeviceMenu")
}

extension NavigationKey {
    init(_ press: KeyPress) {
        self.init(
            name: Self.normalizedName(press),
            characters: press.characters,
            control: press.modifiers.contains(.control),
            shift: press.modifiers.contains(.shift),
            command: press.modifiers.contains(.command),
            option: press.modifiers.contains(.option)
        )
    }

    private static func normalizedName(_ press: KeyPress) -> String {
        if press.key == .upArrow { return "ArrowUp" }
        if press.key == .downArrow { return "ArrowDown" }
        if press.key == .leftArrow { return "ArrowLeft" }
        if press.key == .rightArrow { return "ArrowRight" }
        if press.key == .escape { return "Escape" }
        if press.key == .return { return "Enter" }
        if press.key == .space { return " " }
        if press.key == .delete { return "Backspace" }
        if press.key == .tab { return "Tab" }
        if !press.characters.isEmpty { return press.characters }
        return String(describing: press.key)
    }
}

extension KeyChord {
    var keyEquivalent: KeyEquivalent {
        switch key {
        case " ": return .space
        case "ArrowUp": return .upArrow
        case "ArrowDown": return .downArrow
        case "ArrowLeft": return .leftArrow
        case "ArrowRight": return .rightArrow
        case "Enter": return .return
        case "Escape": return .escape
        case "Backspace": return .delete
        default:
            guard let character = key.first else { return .space }
            return KeyEquivalent(character)
        }
    }

    var eventModifiers: EventModifiers {
        var modifiers: EventModifiers = []
        if control { modifiers.insert(.control) }
        if shift { modifiers.insert(.shift) }
        if command { modifiers.insert(.command) }
        return modifiers
    }
}

struct BindAppFocus: ViewModifier {
    var value: AppFocus
    @Environment(\.appFocus) private var appFocus

    func body(content: Content) -> some View {
        if let appFocus {
            content.focused(appFocus, equals: value)
        } else {
            content
        }
    }
}

struct KeyboardNavigable: ViewModifier {
    var focus: AppFocus
    var handleActivate = true
    var handleArrows = true

    @Environment(KeyboardController.self) private var keyboard
    @Environment(\.appFocus) private var appFocus

    func body(content: Content) -> some View {
        focusedContent(content)
            .focusable(true)
            .onMoveCommand { direction in
                guard handleArrows else { return }
                switch direction {
                case .up: keyboard.perform(.moveUp)
                case .down: keyboard.perform(.moveDown)
                case .left: keyboard.perform(.moveLeft)
                case .right: keyboard.perform(.moveRight)
                default: break
                }
            }
            .onKeyPress(.return) {
                guard handleActivate else { return .ignored }
                keyboard.perform(.activate)
                return .handled
            }
            .onExitCommand { keyboard.perform(.cancel) }
    }

    @ViewBuilder
    private func focusedContent(_ content: Content) -> some View {
        if let appFocus {
            content.focused(appFocus, equals: focus)
        } else {
            content
        }
    }
}

extension View {
    func bindAppFocus(_ value: AppFocus) -> some View {
        modifier(BindAppFocus(value: value))
    }

    func keyboardNavigable(focus: AppFocus, handleActivate: Bool = true, handleArrows: Bool = true) -> some View {
        modifier(KeyboardNavigable(focus: focus, handleActivate: handleActivate, handleArrows: handleArrows))
    }

    func keyboardSelected(_ selected: Bool) -> some View {
        overlay {
            if selected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.green.opacity(0.85), lineWidth: 1.5)
            }
        }
    }
}

/// Hidden key equivalents for global chords. Arrows / Enter / Esc stay on
/// the focused view so text fields keep typing.
struct GlobalKeyboardShortcuts: View {
    var keyboard: KeyboardController

    var body: some View {
        Group {
            ForEach(Array(visibleBindings.enumerated()), id: \.offset) { _, pair in
                Button(pair.action.title) { keyboard.perform(pair.action) }
                    .keyboardShortcut(pair.chord.keyEquivalent, modifiers: pair.chord.eventModifiers)
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private var visibleBindings: [(action: KeyboardAction, chord: KeyChord)] {
        KeyMap.bindings.filter { pair in
            guard !KeyMap.focusedViewActions.contains(pair.action) else { return false }
            if keyboard.navigation.cheatsheetOpen { return false }
            if pair.chord.command { return true }
            if keyboard.isTyping { return false }
            return true
        }
    }
}

struct NSViewCapture: NSViewRepresentable {
    var onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The representable keeps the same NSView identity across updates.
        // Re-publishing it would create an unnecessary @State feedback loop.
    }
}

enum NativeContextMenu {
    static func present(from view: NSView?) {
        guard let view, let window = view.window else { return }
        let local = NSPoint(x: min(28, view.bounds.midX), y: view.bounds.midY)
        let locationInWindow = view.convert(local, to: nil)
        guard let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else { return }
        view.rightMouseDown(with: event)
    }
}
