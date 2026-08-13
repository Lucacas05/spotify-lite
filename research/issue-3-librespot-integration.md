# Integrating librespot with a macOS app

Findings reviewed on 12 August 2026, based on `librespot` v0.8.0 source, its wiki, Homebrew, Apple, and Spotify OAuth documentation.

## Summary

- For Homebrew, the app must find `brew` without assuming a GUI app's `PATH`, check that the formula is installed, and resolve `brew --prefix librespot`. Then it should run `<opt-prefix>/bin/librespot` directly with `Process`.
- If the app already does OAuth PKCE, reuse its access token. Librespot accepts `--access-token` and, in v0.8.0, also `LIBRESPOT_ACCESS_TOKEN`. The token must have the `streaming` scope.
- `--enable-oauth` works, but opens a second OAuth flow owned by librespot and stores credentials in its cache. I would leave it as a fallback, not as SpotifyLite's primary flow.
- `--onevent` is the right mechanism for receiving changes without polling the Web API. It launches a helper program and passes environment variables. It does not deliver a JSON stream on stdout.
- The current stable version of the Homebrew formula and upstream release is `0.8.0`. Verify the real version with `librespot --version`, not only with the formula name.

## 1. Detect and launch the binary from Swift

### Detection

An app launched from Finder/Xcode does not necessarily inherit the user's shell `PATH`. Depending only on `which librespot` is a bad idea.

The recommended flow is:

1. Look for `brew` in the available `PATH` and, as a fallback, in `/opt/homebrew/bin/brew` (Apple Silicon) and `/usr/local/bin/brew` (Intel).
2. Run `brew list --formula --versions librespot`. If it is empty or exits with an error, the formula is not available to the app.
3. Run `brew --prefix librespot` and derive `prefix/bin/librespot`.
4. Check that the file exists and is executable.
5. Run that binary with `--version` and validate the version before starting playback.

Homebrew documents `brew list --versions` for installed versions and recommends `brew --prefix <formula>` to get the stable `opt` prefix, instead of hardcoding a path inside `Cellar`. The `librespot` formula is not keg-only, so `<brew-prefix>/bin/librespot` usually exists as well, but the `opt` prefix is a more stable resolution.

In Swift, the minimal pattern is this (no shell):

~~~
let process = Process()
process.executableURL = librespotURL
process.arguments = [
    "--name", "SpotifyLite",
    "--backend", "rodio",
    "--zeroconf-backend", "dns-sd",
    "--system-cache", cacheURL.path,
    "--onevent", eventHelperURL.path,
]

var environment = ProcessInfo.processInfo.environment
environment["LIBRESPOT_ACCESS_TOKEN"] = freshAccessToken
process.environment = environment

let stdout = Pipe()
let stderr = Pipe()
process.standardOutput = stdout
process.standardError = stderr
process.terminationHandler = { process in
    // log output, termination code, and decide whether to restart
}

try process.run()
~~~

`Process.arguments` already passes an `argv` array; it does not need shell quotes and does not expand `$HOME` or `~`. For logs, read `standardError` asynchronously so the pipe does not fill and block the child. Playback events do not arrive directly on `standardOutput`; they go to the program specified by `--onevent`.

### Watch out for App Sandbox

The current `plan.md` enables App Sandbox, but a dependency in `/opt/homebrew` or `/usr/local` conflicts with that design. Apple documents that a sandboxed app can run programs inside its app bundle, its sandbox container, or an app group, and that the child process inherits the parent's sandbox. User-selected file entitlements do not turn an arbitrary Homebrew path into an allowed executable.

So there are two real alternatives:

- Direct distribution, outside the Mac App Store: remove App Sandbox, keep Hardened Runtime, sign/notarize the app, and treat Homebrew as an optional dependency. This is the option compatible with “the user installs librespot with brew”.
- App Sandbox/Mac App Store: embed your own copy of librespot and the event bridge in the bundle, sign them with the app, and launch them as helpers. That is more reproducible, but the app must own updating that copy.

I would not assume a sandboxed build can freely launch `/opt/homebrew/opt/librespot/bin/librespot`.

## 2. librespot's own OAuth or the app token

### `--enable-oauth`

librespot's built-in flow:

- opens the browser so the user can authorize;
- uses a loopback callback `http://127.0.0.1:<port>/login` (default `5588`);
- requests the scope set librespot has configured, which includes `streaming` and several Spotify app scopes;
- if `--cache` or `--system-cache` is provided, stores reusable credentials so login is not repeated.

It is convenient for running librespot from the terminal, but in SpotifyLite it duplicates the login the app already does and puts credential storage outside the Keychain. It also does not use the app's custom callback (`spotifylite://callback`); it is a separate librespot flow.

### Reuse the app token

The librespot wiki explicitly documents `--access-token` and says the token must include the `streaming` scope. The v0.8.0 source creates `Credentials::with_access_token(...)` with that value. The binary also accepts long options from `LIBRESPOT_*` variables, so `LIBRESPOT_ACCESS_TOKEN` can be used in the `Process` environment instead of putting the token in `arguments`.

The recommendation for this project is:

1. Keep SpotifyLite's OAuth PKCE and request `streaming` together with the Web API scopes the app needs.
2. Check that the `scope` returned by Spotify contains `streaming` before starting librespot.
3. Pass the fresh access token via `LIBRESPOT_ACCESS_TOKEN`; if you do not want to use the environment, pass `--access-token <token>`.
4. Use `--system-cache <directory>` so librespot stores its reusable credential and volume. The directory contains sensitive material: it must have restrictive permissions.
5. Renew the token in the app. Spotify documents that the access token lasts one hour; librespot does not receive the refresh token via CLI. If the process needs to authenticate again, launch it with a fresh token or let it use the reusable credential from its cache.

If a token and `--enable-oauth` are passed at the same time, in v0.8.0 the token wins: the code processes `access-token` first and only enters interactive OAuth when there are no credentials. Do not mix both modes; pick one.

The environment keeps the secret out of the argument list, and librespot's code masks it in its logs, but it is not a secure store by itself. The token and `credentials.json` must be treated as secrets and must never appear in SpotifyLite logs.

### Quick comparison

| Option | Advantage | Cost/risk |
| --- | --- | --- |
| librespot OAuth | Less custom code for first login; built-in cache | Second login, its own loopback callback, broader scopes, and cache outside the Keychain |
| SpotifyLite OAuth token | One login, one refresh, one user session | The app must refresh the token and pass it securely |

For SpotifyLite I would choose the second path. I would leave `--enable-oauth` only as a diagnostic fallback or for a test build.

Note: librespot requires a Spotify Premium account, and its own README warns that use of this client may be restricted by Spotify. That is separate from the technical flow working.

## 3. Events without polling

### `--onevent`

The events wiki describes `--onevent=/path/to/program`. Each time an event is generated, librespot launches that program and passes environment variables. The most useful ones for the UI are:

- `PLAYER_EVENT=track_changed`, with `TRACK_ID`, `URI`, `NAME`, `COVERS`, and additional metadata.
- `PLAYER_EVENT=playing` or `paused`, with `TRACK_ID` and `POSITION_MS`.
- `PLAYER_EVENT=seeked` or `position_correction`, with `TRACK_ID` and `POSITION_MS`.
- `PLAYER_EVENT=end_of_track`, `stopped`, `loading`, `preloading`, and `unavailable`, usually with `TRACK_ID`.
- `PLAYER_EVENT=volume_changed`, with `VOLUME`.
- `session_connected` and `session_disconnected`, with `USER_NAME` and `CONNECTION_ID`.

The bridge can be a small executable inside the app that converts those variables into a JSON line and sends it to SpotifyLite over a Unix domain socket, pipe, or whichever IPC we choose. The bridge must exit quickly after delivering the event.

There is an important subtlety: the documentation calls these events “non-blocking” because they do not block playback threads, but the code does wait for the helper to finish and serializes events to preserve order. A slow bridge can delay later events. Do not use a process that stays open waiting here.

`--emit-sink-events` is optional and adds blocking sink events: `PLAYER_EVENT=sink` with `SINK_STATUS=running`, `temporarily_closed`, or `closed`. It is not needed to reflect track/play/pause and can block the player thread; I would leave it out of the minimum.

### What it does not cover

The standalone binary ignores `PlayerEvent::PositionChanged`; the source itself comments on this. That is why `--onevent` does not send a continuous tick for every millisecond change.

The UI can work without polling like this:

1. On `track_changed`, update track, duration, and artwork.
2. On `playing`, `paused`, `seeked`, and `position_correction`, store `POSITION_MS` and a local `ContinuousClock`.
3. While the state is `playing`, interpolate position locally with elapsed time.
4. Freeze the position on `paused` and reset on `stopped`/`end_of_track`.
5. Use `position_correction` as a resync. An occasional recovery check can help if the bridge dies, but polling the Web API every five seconds is not needed for the normal case.

In other words: yes, playback changes can be reflected without polling; there is no standalone event that by itself delivers a continuous position.

### Practical detail of the bridge path

The v0.8.0 implementation splits the `--onevent` string on spaces before running the command. Pass an absolute path with no spaces, or use a wrapper with a safe path; do not rely on shell quotes inside the `--onevent` value.

## 4. Version and minimum flags

The latest upstream release consulted is [v0.8.0, published 10 November 2025](https://github.com/librespot-org/librespot/releases/tag/v0.8.0). The [Homebrew formula](https://formulae.brew.sh/formula/librespot) also marks `0.8.0` as stable. On Homebrew for macOS it is built with `rodio-backend`, `with-dns-sd`, and system TLS roots; `rodio` uses CoreAudio on macOS.

With the SpotifyLite token, a reasonable minimum is:

~~~
librespot
  --name SpotifyLite
  --backend rodio
  --zeroconf-backend dns-sd
  --system-cache <Application Support>/SpotifyLite/librespot
  --onevent <absolute-bridge-path-without-spaces>
~~~

And in `Process.environment`:

~~~
LIBRESPOT_ACCESS_TOKEN=<fresh access token with streaming scope>
~~~

I would not add `--disable-discovery`, because the goal is for the device to appear in Spotify Connect. `--cache <path>` is optional: besides credentials it stores audio files; `--system-cache` is enough to start. `--bitrate 320`, `--device-type computer`, normalization, and initial volume are product decisions, not launch requirements.

If using librespot's own OAuth, switch authentication to `--enable-oauth` and keep `--system-cache`; do not pass `LIBRESPOT_ACCESS_TOKEN` at the same time. Only use `--oauth-port` if port 5588 is in use or you need headless mode.

Finally, run `librespot --version` from the app and log the result (no tokens). If the user has `--HEAD` or a different version, show a clear diagnosis: options and the internal protocol can change.

## Primary sources

- [Homebrew: librespot formula](https://formulae.brew.sh/formula/librespot)
- [Homebrew: brew(1), `list --versions`](https://docs.brew.sh/Manpage)
- [Homebrew: `brew --prefix <formula>`](https://docs.brew.sh/How-to-Build-Software-Outside-Homebrew-with-Homebrew-keg-only-Dependencies)
- [Apple: `Process.arguments`, `executableURL`, and pipes](https://developer.apple.com/documentation/foundation/process/arguments)
- [Apple: App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
- [Apple: accessing files from App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [librespot Wiki: Options](https://github.com/librespot-org/librespot/wiki/Options)
- [librespot Wiki: Authentication / OAuth](https://github.com/librespot-org/librespot/wiki/Options#oauth)
- [librespot Wiki: Access token](https://github.com/librespot-org/librespot/wiki/Options#access-token)
- [librespot Wiki: Events](https://github.com/librespot-org/librespot/wiki/Events)
- [librespot v0.8.0: `src/main.rs`](https://github.com/librespot-org/librespot/blob/v0.8.0/src/main.rs#L700-L737)
- [librespot v0.8.0: cache and credential precedence](https://github.com/librespot-org/librespot/blob/v0.8.0/src/main.rs#L1136-L1232)
- [librespot v0.8.0: reusable credential storage](https://github.com/librespot-org/librespot/blob/v0.8.0/core/src/session.rs#L206-L257)
- [librespot v0.8.0: interactive OAuth](https://github.com/librespot-org/librespot/blob/v0.8.0/src/main.rs#L1945-L1969)
- [librespot v0.8.0: binary events](https://github.com/librespot-org/librespot/blob/v0.8.0/src/player_event_handler.rs#L297-L361)
- [librespot README: cache and credentials](https://github.com/librespot-org/librespot/blob/v0.8.0/README.md#usage)
- [Spotify: Authorization Code with PKCE](https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow)
- [Spotify: Access token](https://developer.spotify.com/documentation/web-api/concepts/access-token)
- [Spotify: scopes](https://developer.spotify.com/documentation/web-api/concepts/scopes)
- [Upstream issue on `--onevent` and program permissions](https://github.com/librespot-org/librespot/issues/367)
