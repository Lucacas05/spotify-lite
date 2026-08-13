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

`streaming` is reserved for experimental local playback (not in this beta yet). Remote control uses the `user-*-playback-state` and `user-read-currently-playing` scopes.

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

They cover PKCE, tokens, OAuth scopes, and the main Web API payloads.

## Troubleshooting

| Symptom | What to check |
|---|---|
| `INVALID_CLIENT: Invalid client` | Client ID pasted incorrectly. Copy it again from the dashboard. |
| `Invalid redirect URI` / `Insecure redirect URI` | The URI in the dashboard must be exactly `http://127.0.0.1:8888/callback`. Do not use `localhost` or custom schemes. |
| HTTP 403 *User not registered* | Add that account under *User Management* for your app. |
| HTTP 403 when controlling the player | Premium account and an active Connect device. |
| HTTP 404 when playing | Open Spotify on your phone, desktop, or another device. |
| *Set your Spotify Client ID…* | The login field is empty. |
| Browser does not return to the app / port in use | Nothing else should be listening on `127.0.0.1:8888`. |
| `xcodebuild: scheme SpotifyLite not found` | Run `xcodegen generate`. |
| Xcode asks for a Team | *Signing & Capabilities* → your Personal Team, or use the `CODE_SIGNING_ALLOWED=NO` build. |

Notarized packaging (DMG, Developer ID) is not part of this beta; see `RELEASE.md`.
