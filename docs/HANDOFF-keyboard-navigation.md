# Handoff: Full keyboard navigation for SpotifyLite

**Repo:** `/Users/lucas/Documents/1 Projects/spotify` (branch `main`, clean at handoff time)
**App:** SpotifyLite — native macOS Spotify client, Swift/SwiftUI, XcodeGen (`project.yml`), local playback via librespot.
**Status:** Design is fully decided and confirmed by the user through a grilling session. Nothing has been implemented yet. Your job is to execute the phases below.

## Goal

Anyone using the app can do everything with the keyboard, no mouse required. Two layers:

1. Standard navigation (arrows, Tab, Enter, Space) that works with zero learning.
2. Optional single-letter shortcuts for power users.

## Validated interaction model (do not re-litigate — user confirmed all of this)

An interactive prototype validated the model. It lives at
`SpotifyLite/Views/Prototype/KeyboardZonesPrototype.html` (throwaway, single file, open in a browser).
Its `NavModel` module is a **pure reducer `(state, key) → state`** written to be ported to Swift as the central navigation model. Read it before implementing — it encodes every rule below plus edge cases (search typing mode, empty queue, cheatsheet modality).

### Focus zones

- Direct jump keys: `1` Sidebar, `2` Track list, `3` Queue, `4` Player bar, `/` Search (enters typing mode).
- `⌃`+arrows move between zones spatially (sidebar ← list → queue; player below; search above).
- Inside a zone: arrows move, Enter activates.
- Player zone: `←`/`→` move focus across controls; `⇧`+`←`/`→` seek ±10s; Enter activates the focused control.
- Opening a playlist with Enter auto-jumps focus from sidebar to the track list (confirmed as desired).
- Queue stays a **popover** (as in the current app): `3` toggles it, focus moves into it on open, Esc closes and restores focus.
- Search field: keys type text (digits included — they must NOT switch zones while typing); `↓` or Enter jumps to results; Esc exits back to the list zone.
- **Remove** the existing `Cmd+1` / `Cmd+2` shortcuts so numbers have one meaning. Keep `Cmd+F` and Space.

### Track actions

- `m` opens the native context menu of the selected track row (guarantees everything is reachable).
- `a` adds the selected track to the queue directly.

### Single-letter shortcut set (fixed, exactly this set)

`n` next, `p` previous, `s` shuffle toggle, `a` add to queue, `+`/`-` volume.

### Command palette

`Cmd+K`: navigation (playlists, sections) + tracks + actions (pause, shuffle, switch device).
API constraint: the app runs in Spotify dev mode — search returns at most 10 results; playlist tracks come via `GET /playlists/{id}` with an `item` wrapper (the `/tracks` endpoint 403s).

### Discoverability & customization

- `?` opens a cheatsheet overlay (Esc or `?` closes).
- Keybinds are **fixed**, but defined in one central map of named actions (`playPause`, `focusSidebar`, …) separated from their keys.
- README gets a ready-made prompt users can paste to their own agent to customize keybinds (the prompt should tell the agent to ask the user questions and then edit the central key map).

### Global playback

System media keys only (F8/F9/F10). No custom global shortcuts.

### Implementation constraint (user confirmed as a goal)

Build on **SwiftUI's native focus system** (`@FocusState`, focusable rows, key handling on focused views) rather than intercepting all key events — so macOS Full Keyboard Access and VoiceOver work nearly for free. Port the prototype's reducer as the navigation model; views bind to it.

## Delivery order (confirmed)

1. **Phase 1:** focus model + zones + Enter-to-play on track rows. App becomes fully usable without a mouse.
2. **Phase 2:** command palette `Cmd+K`.
3. **Phase 3:** cheatsheet `?`, single-letter shortcuts, queue-popover focus/Esc handling, README customization prompt.

## Codebase facts (from exploration — verified 2026-08-13)

- Views: `SpotifyLite/Views/` — `SidebarView`, `SearchView`, `TrackListView`, `QueueView`, `PlayerBarView`, `MainWindow`, `AlbumArtistViews`, `MenuBarPlayerView`. Player logic in `SpotifyLite/Player/PlayerStore.swift`.
- Existing shortcuts: hidden buttons in `MainWindow.swift:170-189` — `Cmd+F` (focus search via `NotificationCenter` `.focusSpotifySearch`), `Cmd+1` (Search section), `Cmd+2` (Liked Songs), `Space` (play/pause). This is the pattern to replace with the central action/key map.
- Track rows activate only via double-click today; no focus model anywhere; queue popover assigns no focus on open and has no Esc handling.
- Queue and device menus are buttons inside the player bar, so zone `4` + Enter reaches them; once open they are native menus (keyboard-navigable by macOS).
- No settings scene / preferences window / keybinding persistence exists. Small `@AppStorage` usage in `SpotifyLiteApp.swift`, `MainWindow.swift`, `MenuBarPlayerView.swift`.
- `SpotifyLite/Views/Prototype/` already holds Swift prototype files — precedent for prototype placement.

## Suggested skills

- `mattpocock-skills:codebase-design` — before Phase 1, to shape the central action/keybinding module (deep module: views depend on named actions, not keys).
- `run` — to launch the app and verify each phase in the real UI (it's an Xcode/XcodeGen project; see `scripts/` and `README.md`).
- `mattpocock-skills:code-review` — after each phase, review against this handoff as the spec.
- `mattpocock-skills:tdd` — the ported navigation reducer is pure and ideal for test-first porting (`SpotifyLiteTests` exists).
- `update-docs` — for the README keybinds section + customization prompt in Phase 3.

## Notes for the executing agent

- The prototype HTML is throwaway; per the prototype skill it should eventually be committed to a throwaway branch, not `main`.
- User writes in Spanish (Peruvian, "tú") but the repo/docs/commits are in English. README prompt for keybind customization should be in English.
- Do not add Co-Authored-By/Claude attribution lines to commits (user rule).
- No secrets in this doc; OAuth tokens live in the macOS Keychain, Client ID in UserDefaults — leave both alone.
