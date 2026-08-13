# SpotifyLite

Native Spotify client for macOS (SwiftUI). This technical beta runs from the clone: remote control of an active Spotify Connect device, with no notarized binary.

Login uses OAuth 2.0 Authorization Code + PKCE. The password is entered only on Spotify's page. There is no Client Secret: do not copy it, paste it, or commit it to the repository.

## Requirements

| Requirement | Version / detail |
|---|---|
| macOS to **run** the app | 14.0 Sonoma or later (`project.yml`) |
| Xcode to **build** | 16 or later |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | 2.x (`brew install xcodegen`) |
| Spotify account | **Premium** (see [Premium](#premium)) |
| App in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard) | Your own Client ID; no secrets in the repo |

Homebrew is only needed to install XcodeGen. An Apple Developer Program account is not required for this beta: a personal Xcode team or an unsigned local build is enough.

## Clone and generate the project

`project.yml` is the source of truth. The `.xcodeproj` is regenerated with XcodeGen (it includes the shared `SpotifyLite` scheme, required for `xcodebuild`).

```bash
git clone https://github.com/Lucacas05/spotify-lite.git
cd spotify-lite
brew install xcodegen
xcodegen generate
```

## App in the Spotify Developer Dashboard

1. Open [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) and create an app.
2. Name and description are up to you. Check **Web API**. Accept the Developer Terms.
3. Under Redirect URIs, register **exactly** this value (copy and paste):

   ```text
   http://127.0.0.1:8888/callback
   ```

   The match is literal: `http` (not `https`), `127.0.0.1` (**not** `localhost`), port `8888`, and path `/callback` with no trailing slash. Since 2025 Spotify only documents `https://` and loopback URIs as safe; `localhost` is not allowed.
4. Copy the **Client ID**. The Client Secret shown in the dashboard **is not used** (PKCE flow). Do not store it in the repo.
5. In Development Mode, the app owner is already authorized. If another account signs in, add it under *User Management* (maximum 5 users per app).

The URI and scopes are fixed in `SpotifyAuthConfig` (`SpotifyLite/Auth/AuthManager.swift`). No code changes are required.

## How to set the Client ID

The app **does not** ship with a factory Client ID. Each clone uses its own:

1. Launch SpotifyLite.
2. On the login screen, paste the Client ID into the field.
3. Click **Log in with Spotify**.

`AuthManager` trims whitespace, rejects login if the field is empty, and stores the value in `UserDefaults` under the `clientID` key. It survives restarts. Tokens go to the Keychain (`com.lucas.spotifylite`), never to plain disk.

There is no secrets template or environment variable: the Client ID is not an OAuth secret, but versioning it would share your app quota. `.gitignore` ignores `.env` and `Secrets.xcconfig` in case someone creates them by mistake.

## Scopes

The app requests exactly:

```text
user-read-playback-state
user-modify-playback-state
user-read-currently-playing
playlist-read-private
playlist-read-collaborative
user-library-read
user-read-private
streaming
```

`streaming` is used by local playback (see below). Remote control uses the `user-*-playback-state` and `user-read-currently-playing` scopes.

## Local playback (play on this Mac)

The app can play audio by itself, with no official Spotify client open anywhere. It launches [librespot](https://github.com/librespot-org/librespot) as a child process that registers this Mac as a Spotify Connect device named **SpotifyLite**, then transfers playback to it. Audio goes straight to CoreAudio.

1. Install librespot once:

   ```bash
   brew install librespot
   ```

2. In the player bar, open the device menu (speaker icon) and click **Play on this Mac**.

Details:

- librespot authenticates with the app's own OAuth token (`streaming` scope); there is no second login and no credentials outside your machine.
- Requires **Premium** (librespot limitation).
- The child process stops when you quit the app or click **Stop local player**.
- While SpotifyLite is the active device, the track appears in the macOS Now Playing widget (Control Center / Lock Screen / Touch Bar) with title, artist, album, artwork, and progress. Media keys and AirPods controls play, pause, skip, and go back.
- Its credential cache lives in `~/Library/Application Support/SpotifyLite/librespot` with owner-only permissions.

**Note:** librespot is an unofficial client and its use is against Spotify's terms of service (same as Psst, ncspot, etc.). In practice it is tolerated, but there is a theoretical risk to the account. That is why it is opt-in and the binary is installed by you, not shipped with the app.

## Premium

A **Premium** account is required in two places:

- **App owner** in Development Mode (Spotify change from February 2026): if the owner's Premium lapses, the app stops working.
- **Playback control**: Player endpoints (`play`, `pause`, `next`, seek, volume, device) only work with Premium. Without an active Connect device, the API returns 404.

Browsing playlists and searching may work with a Free account, but this beta assumes Premium because each user creates their own app.

## Build and run

### From Xcode

```bash
xcodegen generate
open SpotifyLite.xcodeproj
```

Scheme `SpotifyLite`, destination *My Mac*. In *Signing & Capabilities*, pick your Team (Personal Team is fine). ⌘R.

### From the terminal (unsigned)

```bash
xcodegen generate
xcodebuild -project SpotifyLite.xcodeproj -scheme SpotifyLite \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO build
open build/Build/Products/Debug/SpotifyLite.app
```

On first launch, macOS may ask you to confirm an unsigned app: right-click → Open.

To use the player, leave an official Spotify client (or another Connect device) running.

## Tests

They need neither a Client ID nor a network:

```bash
xcodegen generate
xcodebuild test -project SpotifyLite.xcodeproj -scheme SpotifyLite \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

They cover PKCE, tokens, OAuth scopes, Web API payloads, keyboard navigation, and Now Playing metadata / media-key dispatch.

## Keyboard shortcuts

The app is fully usable from the keyboard. Focus lives in one of five zones: Search, Sidebar, Track list, Queue (popover), and Player.

| Keys | Action |
|---|---|
| `1` `2` `3` `4` | Focus sidebar / track list / queue (toggle) / player |
| `/` or `⌘F` | Focus search (typing mode; digits type into the field) |
| `⌃` + arrows | Move between zones spatially |
| `↑` `↓` `←` `→` | Move inside the current zone |
| `Enter` | Activate (open playlist, play track, press the focused player control) |
| `Space` | Play / pause (global, except while typing in search) |
| `Esc` | Leave search, close the queue popover, or close an overlay |
| `⇧←` `⇧→` | Seek −10s / +10s (player zone) |
| `n` `p` `s` | Next / previous / shuffle |
| `a` | Add the selected track to the queue |
| `m` | Open the selected track’s context menu |
| `+` `-` | Volume up / down |
| `⌘K` | Command palette (playlists, tracks, playback, devices) |
| `?` | Keyboard shortcut cheatsheet |

`⌘1` / `⌘2` are intentionally unbound so the number keys have a single meaning.

System media keys (previous / play-pause / next; F7–F9 or F8–F10 depending on the Mac and Fn settings) control playback **only while this Mac is the active SpotifyLite device**. They work with the app focused, in the background, and with the window closed. Seeking from Control Center is not supported. Playback on a phone or another Connect device does not take over the Mac’s Now Playing slot. There are no other global (out-of-app) shortcuts.

### Customize keybinds

Shortcuts are **not** editable in the UI. They live in one table: `SpotifyLite/Keyboard/KeyMap.swift` (`KeyMap.bindings`). Views depend on named actions (`playPause`, `focusSidebar`, …), never on raw keys.

If you use an AI coding agent, paste this prompt:

> I want to customize SpotifyLite keyboard shortcuts. Ask me which actions to remap and which keys to use, one question at a time if anything is ambiguous. Then edit only `KeyMap.bindings` in `SpotifyLite/Keyboard/KeyMap.swift`. Do not rename `KeyboardAction` cases, and do not change `NavigationModel` or the views unless a new action is required. Keep `⌘F` (search) and `Space` (play/pause) unless I explicitly ask to move those. After editing, confirm the cheatsheet still lists the new chords (it reads from `KeyMap`) and run `KeyboardNavigationTests`.

## Troubleshooting

| Symptom | What to check |
|---|---|
| `INVALID_CLIENT: Invalid client` | Client ID pasted incorrectly. Copy it again from the dashboard. |
| `Invalid redirect URI` / `Insecure redirect URI` | The URI in the dashboard must be exactly `http://127.0.0.1:8888/callback`. Do not use `localhost` or custom schemes. |
| HTTP 403 *User not registered* | Add that account under *User Management* for your app. |
| HTTP 403 when controlling the player | Premium account and an active Connect device. |
| HTTP 404 when playing | Open Spotify on your phone, desktop, or another device. |
| Media keys / Now Playing do nothing | Play on this Mac first (librespot must be the active **SpotifyLite** device). Remote control of a phone or another computer does not claim the Mac’s controls. |
| Now Playing still shows SpotifyLite after switching devices | Wait up to ~30 s if the window is in the background; it should clear on the next poll. Foreground updates within a few seconds. |
| *Set your Spotify Client ID…* | The login field is empty. |
| Browser does not return to the app / port in use | Nothing else should be listening on `127.0.0.1:8888`. |
| `xcodebuild: scheme SpotifyLite not found` | Run `xcodegen generate`. |
| Xcode asks for a Team | *Signing & Capabilities* → your Personal Team, or use the `CODE_SIGNING_ALLOWED=NO` build. |

Notarized packaging (DMG, Developer ID) is not part of this beta; see `RELEASE.md`.
