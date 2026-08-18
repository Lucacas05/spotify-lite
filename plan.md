# Plan: Lightweight Spotify player for macOS (SwiftUI)

A native Spotify client for macOS, built with SwiftUI, that uses few resources (target: < 50 MB RAM, < 1% CPU at idle) and logs in via official Spotify OAuth — the user signs in on Spotify's page and never types their password in the app.

## Prerequisites

- macOS 14+ (Sonoma) as the target. Xcode 16+.
- A Spotify **Premium** account only if optional local playback (librespot) is used; remote-control mode works with the official endpoints.
- App registered in the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard):
  - Redirect URI: `http://127.0.0.1:8888/callback` (loopback; since 2025 Spotify only documents `https://` and loopback as safe — custom schemes return `INVALID_CLIENT: Insecure redirect URI` on new apps)
  - Note the `Client ID` (no client secret is needed thanks to PKCE).

## Key decisions

| Decision | Choice | Why |
|---|---|---|
| UI | Pure SwiftUI | Native, lightweight, no Electron/Qt |
| Auth | OAuth 2.0 Authorization Code + PKCE with browser + local loopback server | Login on Spotify's official page; loopback (`http://127.0.0.1`) is the only form documented as safe for desktop since 2025, with no client secret |
| Metadata / playlists / search | Spotify Web API with `URLSession` + `Codable` | No external dependencies |
| Playback | Remote control via Web API by default; **external** librespot (installed by the user with brew), experimental | Spotify does not offer a desktop playback SDK; not embedding librespot keeps the published app 100% official API |
| Tokens | Keychain | Never in UserDefaults or on plain disk |
| Dependencies | Zero third-party Swift packages | Smaller surface, smaller footprint |

**Legal note:** the published app uses only the official API (remote control). Using librespot goes against Spotify's terms of service (like all unofficial clients: Psst, ncspot, etc.); in practice it is tolerated, but there is a theoretical risk of account bans. That is why local playback is opt-in, requires the user to install librespot themselves, and is marked as experimental/unofficial.

## Architecture

```
┌─────────────────────────────────────────────┐
│                 SwiftUI Views                │
│  Sidebar · PlaylistView · SearchView ·       │
│  PlayerBar · NowPlaying                      │
└──────────────┬──────────────────────────────┘
               │ @Observable
┌──────────────┴──────────────────────────────┐
│                ViewModels / Store            │
└───────┬─────────────────┬───────────────────┘
        │                 │
┌───────┴───────┐ ┌───────┴───────────────────┐
│  AuthManager  │ │      SpotifyClient         │
│  (PKCE, Key-  │ │  (Web API: URLSession +    │
│   chain, re-  │ │   Codable, rate limiting)  │
│   fresh)      │ └───────┬───────────────────┘
└───────────────┘         │ player endpoints
                  ┌───────┴───────────────────┐
                  │     PlayerEngine           │
                  │  external librespot (brew) │
                  │  optional child process    │
                  │  + MPNowPlayingInfoCenter  │
                  └───────────────────────────┘
```

How music plays: by default, the app controls playback on any active Spotify Connect device via the Web API. If the user enables experimental mode and has librespot installed (brew), the app launches it as a child process registered as a Connect device named "SpotifyLite", selects it via `PUT /me/player`, and controls everything (play, pause, seek, queue) with the `player` endpoints. Audio comes from librespot directly to CoreAudio.

## Project structure

```
SpotifyLite/
├── SpotifyLiteApp.swift          # @main, main scene
├── Auth/
│   ├── AuthManager.swift         # PKCE flow, ASWebAuthenticationSession
│   ├── PKCE.swift                # verifier/challenge (CryptoKit)
│   └── KeychainStore.swift       # save/read/delete tokens
├── API/
│   ├── SpotifyClient.swift       # HTTP layer: auth header, refresh, retry 429
│   ├── Endpoints.swift           # typed Web API routes
│   └── Models/                   # Codable: Track, Album, Playlist, Device...
├── Player/
│   ├── LibrespotLocator.swift    # detect brew install, validate version
│   ├── LibrespotProcess.swift    # launch/supervise the external binary
│   ├── PlayerEngine.swift        # playback state (Web API polling)
│   └── NowPlayingBridge.swift    # MPNowPlayingInfoCenter, media keys
├── Views/
│   ├── MainWindow.swift          # NavigationSplitView (sidebar + detail)
│   ├── LoginView.swift
│   ├── SidebarView.swift         # Library, playlists
│   ├── PlaylistDetailView.swift
│   ├── SearchView.swift
│   └── PlayerBarView.swift       # bottom bar: track, controls, volume
└── plan.md                       # this file
```

## Phases

### Phase 0 — Project setup (½ day)

- [x] Create Xcode project: macOS app, SwiftUI, bundle id `com.lucas.spotifylite`.
- [x] No App Sandbox (required to launch the user's external librespot); Hardened Runtime enabled. Distribution: Developer ID + notarization, outside the App Store.
- [x] Register the app in the Spotify Developer Dashboard and save the Client ID.

### Phase 1 — Spotify OAuth login (1–2 days)

The core of what you asked for: tapping "Log in" opens Spotify's official page; the user authenticates there and Spotify redirects back to the app.

- [x] `PKCE.swift`: generate `code_verifier` (64 random chars) and `code_challenge` (SHA256 + base64url) with CryptoKit.
- [x] `AuthManager.login()`:
  - Build the `https://accounts.spotify.com/authorize` URL with `client_id`, `response_type=code`, `redirect_uri=http://127.0.0.1:<port>/callback`, `code_challenge_method=S256`, `code_challenge`, and `scope`.
  - Scopes: `user-read-playback-state user-modify-playback-state user-read-currently-playing playlist-read-private playlist-read-collaborative user-library-read user-read-private streaming`.
  - Start an ephemeral local HTTP server on `127.0.0.1` (Network.framework) and open the URL in the default browser with `NSWorkspace.open` (if a Spotify session already exists in the browser, it is one click).
  - On the HTTP callback, extract `code`, respond with a "return to the app" page, and shut the server down.
- [x] `AuthManager.exchangeCode()`: `POST https://accounts.spotify.com/api/token` with `grant_type=authorization_code`, `code`, `redirect_uri`, `client_id`, `code_verifier`. Response: `access_token` (expires in 1 h) + `refresh_token`.
- [x] `KeychainStore`: save both tokens in the Keychain.
- [x] Automatic refresh: interceptor in `SpotifyClient` that renews the token when it expires (or on a 401) with `grant_type=refresh_token`, serialized with an actor to avoid concurrent refreshes.
- [x] `LoginView`: initial screen with a "Log in with Spotify" button; on completion, go to `MainWindow`.
- [x] Logout: clear the Keychain and return to `LoginView`.

**Exit criterion:** open the app → log in on Spotify's page → the app shows your username (`GET /me`) and survives restarts without asking to log in again.

### Phase 2 — Library and search, remote-control mode (3–4 days)

With only the Web API the app is already useful: browse your music and control playback on any active device (the official client, a speaker). All of this is 100% official API.

- [x] `SpotifyClient`: generic `request<T: Codable>` layer with auth header, decoding, 401 handling (refresh), and 429 handling (honor `Retry-After`).
- [x] Minimal `Codable` models: `Track`, `Album`, `Artist`, `Playlist`, `PlaybackState`, `Device`.
- [x] `SidebarView`: user's playlists (`GET /me/playlists`, paginated) + Liked Songs.
- [x] `PlaylistDetailView`: tracks with `LazyVStack` (playlists of thousands of songs without a memory cost), artwork with cache (`URLCache` configured, ~50 MB on disk).
- [x] `SearchView`: `GET /search` with 300 ms debounce.
- [x] `PlayerBarView`: current track, play/pause, next/previous, volume, device picker (`GET /me/player/devices`).
- [x] Playback state: poll `GET /me/player` every 5 s when the window is active (pause polling in the background to save CPU).

**Exit criterion:** search for a song, play it on the active device, control play/pause/volume from the app.

> **Note (updated in Phase 3, Aug 2026):** apps in dev mode registered since 2025 have particular Web API limits: `/search` accepts `limit` ≤ 10, `/me/tracks` ≤ 50, and the old `/playlists/{id}/tracks` endpoint should no longer be used. `GET /playlists/{id}` returns the first page under `items`; remaining pages are loaded from `GET /playlists/{id}/items` with `offset`. Each entry wraps the track in the `item` key (not `track`). Verified with a 343-track playlist and implemented in `TrackListView`/`SearchView`.

### Phase 3 — Polish, performance, and first release (2–3 days)

The first release is remote-control only: 100% official API, no librespot.

Before preparing the DMG, a technical beta that can be run from the repository clone will be published. This lets iteration and feedback continue without blocking on signing and notarization. The repository must include reproducible instructions to configure the project, register the Spotify redirect URI, enter the Client ID, and run the app.

- [x] Playback queue and "play next".
- [x] Album and artist views.
- [x] Keyboard shortcuts (space = play/pause, ⌘F = search, ⌘1/2 = navigation).
- [x] Optional menu bar icon (current track + controls) with `MenuBarExtra`.
- [x] Profile performance: 45 MB RAM and 0% CPU observed at idle/background; repeat with Instruments before release (see `PERFORMANCE.md`).
- [x] Light/dark mode, empty states, visible error handling (offline, revoked token, no Premium).
- [x] Interactive timeline for the playing track: show elapsed time and duration, interpolate progress between polls, allow dragging to seek, then reconcile with the state confirmed by Spotify.
- [x] Technical beta from the clone: README, requirements, OAuth/Client ID setup, and reproducible steps to run the app.
- [ ] Packaging after the technical beta: Developer ID signing, hardened runtime, notarization, and DMG. The brew cask comes later, pointing at the same notarized artifact.

**Exit criterion:** first, a technical beta reproducible from the clone; then a notarized, downloadable, installable DMG with the complete app in remote-control mode.

### Phase 4 — Local playback with external librespot (2–3 days, post-release)

Experimental: the user installs librespot themselves (brew); the app never embeds it.

> **Decisions updated during implementation (Aug 2026) and issue #16:**
> - **Opt-in, no Settings toggle, no 404 auto-start.** Remote control stays the default. A normal Play after 404 / no active device does **not** launch librespot (`PERFORMANCE.md`). Until the current Spotify account consents, the device menu shows **This Mac (set up…)** and opens a consent sheet (ToS/warning + setup: copyable `brew install librespot` and **Check again**), not docs-only. After consent the item becomes **Play on this Mac** and may start librespot. Consent is stored per Spotify account so it is not asked on every play. Remote devices work without ever opting in.
> - **Auth is librespot's own OAuth, not the app's PKCE token.** Tokens issued to a custom client ID pass the classic session login but are then denied by login5 with `INVALID_CREDENTIALS` when spirc registers the Connect device. `--enable-oauth` (librespot's own client ID) is used for a one-time browser approval; reusable credentials land in the per-account system cache and later launches log in silently. The unused `validAccessToken()` path is not auto-wired. If Spotify rejects the cached credentials, they are reset automatically and the next start re-authorizes.
> - **Credentials are per account.** Cache lives in `Application Support/SpotifyLite/librespot/accounts/<spotify-user-id>/`. Logout / account switch deletes that account's `credentials.json` as well as the Web API token. No credential inheritance across accounts.
> - **Locator:** `brew --prefix` / `brew --prefix librespot` (absolute brew path, no GUI PATH, run off the main actor) plus the fixed `opt`/`bin` fallbacks. First executable that runs and meets 0.8.0 wins; unknown version warns in the log and proceeds (does not hard-block). **No extra version UI** — no Settings row, about panel, or librespot version badge. Too-old binaries use the existing `.failed` banner (`brew upgrade librespot`) only when no usable candidate remains.
> - **Supervisor (#17):** `start()` is single-flight and only from the #16 path (`playOnThisMac` / Retry, after the per-account consent gate). **Never** 404 / no-device / discovery success. Crash/nonzero restarts with backoff 1 s/2 s/4 s **only for that user-started session**; then degrade to remote + banner and **stop** launching. No extra Now Playing poll — existing 5 s / 30 s playback poll; ownership is device id; 204/no track releases. No `--onevent` bridge in 0.2.
> - **Now Playing ownership** is the exact local Connect **device id**, not the name `"SpotifyLite"`. 204 / no track releases the system lock.

- [x] `LibrespotLocator`: `brew --prefix` plus fixed Homebrew `opt`/`bin` paths; first runnable binary meeting 0.8.0; unknown version warns instead of blocking.
- [x] Validate version with `librespot --version`: skip candidates < 0.8.0 (existing `.failed` message "update with `brew upgrade librespot`" if none remain); newer or unparseable versions proceed. Unknown version is an `os.Logger` warning only — not a Settings row, about panel, badge, or extra banner.
- [x] Setup sheet when librespot is missing: copyable `brew install librespot`, experimental/ToS/Premium warning, and a "Check again" button. The app does not run brew.
- [x] `LibrespotEngine`: launch the external binary with `Process`:
  - `librespot --name "SpotifyLite" --backend rodio --zeroconf-backend dns-sd --device-type computer --bitrate 320 --system-cache <Application Support>/SpotifyLite/librespot/accounts/<spotify-user-id>` (plus `--enable-oauth` on first run only). No `--onevent`.
  - Lifetime wrapper (`LibrespotProcessLifetime`): a bash trap tied to a stdin pipe kills librespot if the app dies for any reason (crash, SIGKILL, Xcode stop); stale orphans are reaped before every start.
  - Supervision: `start()` is single-flight and only after explicit opt-in. If a **user-started** process dies with crash/nonzero, restart with backoff (3 attempts: 1 s/2 s/4 s; the budget resets after 60 s of healthy uptime); if it keeps failing, fall back to remote-control mode with a banner and **stop launching** until the user opts in again. stderr is logged to Application Support (no tokens).
- [x] On activation, transfer playback to the registered Connect device (`PUT /me/player` with its **device id**), waiting for the Connect registration to appear. The name `"SpotifyLite"` is only how we discover that id.
- [x] Playback state: reuse Phase 2 polling (the `--onevent` event bridge remains a future improvement).
- [x] `NowPlayingBridge`: `MPNowPlayingInfoCenter` (title, artist, artwork, position) + `MPRemoteCommandCenter` (keyboard media keys, AirPods). Claim only while the active device id equals the local id; 204 / no track releases the system Now Playing lock.

**Exit criterion:** with librespot installed, the app plays audio itself, responds to media keys, and appears in the macOS Now Playing widget; without librespot, the app remains complete in remote-control mode and offers the setup sheet.

## Future improvements (unestimated)

- librespot event bridge (`--onevent` + embedded helper that forwards to the app over a Unix socket): replaces polling with instant events and local position interpolation.
- Brew cask (after the first DMG) and, if needed, Sparkle for automatic updates outside brew.

## Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| librespot stops working due to Spotify changes | No local audio | Remote-control mode (Phase 2) still works; librespot has an active community that patches it quickly |
| Account ban due to ToS | Account loss | Theoretical risk and historically not enforced against users; document it in the README; offer control-only mode |
| Web API rate limits | Slow UI | Aggressive metadata cache, poll only with the window active, honor `Retry-After` |
| No Premium account | Playback does not work | Detect `product != "premium"` in `GET /me` and limit the app to remote-control mode with a clear notice |
| Web API quota in development mode | Only 25 authorized users | Enough for personal use; request a quota extension only if distributing |

## Total estimate

~1.5 to 2 weeks part-time until the first release (end of Phase 3, remote control only). Phase 2 alone already yields a useful app in the first week. Local playback with librespot (Phase 4) adds 2–3 days in a later version.

## References

- [Authorization Code Flow with PKCE — Spotify](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow)
- [Spotify Web API Reference](https://developer.spotify.com/documentation/web-api)
- [librespot](https://github.com/librespot-org/librespot)
- [Psst](https://github.com/jpochyla/psst) — lightweight client reference (Rust)
- [ASWebAuthenticationSession — Apple](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)
