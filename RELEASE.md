# SpotifyLite release

## One-time setup

1. Have a **Developer ID Application** certificate installed in the Keychain.
2. Store notarization credentials without committing secrets to the repository:

```bash
xcrun notarytool store-credentials spotifylite-notary \
  --apple-id "your-apple-id" --team-id "TEAMID" --password "app-specific-password"
```

3. Confirm that `project.yml` contains the correct version.

## Create the DMG

```bash
DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
DEVELOPMENT_TEAM="TEAMID" \
NOTARY_PROFILE="spotifylite-notary" \
./scripts/release.sh
```

The script produces `build/release/SpotifyLite-<version>.dmg` and its SHA-256. It archives a Release build, signs with Hardened Runtime, notarizes and staples both the app and the DMG, and validates the result with `codesign`, `stapler`, and `spctl`.

## Automated tests

Before creating the DMG:

```bash
xcodegen generate
xcodebuild test -project SpotifyLite.xcodeproj -scheme SpotifyLite \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

The suite covers PKCE, token expiry and serialized persistence, OAuth scopes, and decoding of the main Spotify payloads.

## Manual validation before publishing

- Install the DMG on a macOS account where SpotifyLite has never been launched.
- Complete OAuth, restart the app, and verify that the session persists.
- Exercise search, playlists, Liked Songs, album/artist, queue, device picker, and controls.
- Temporarily revoke network/token access and verify that a recoverable error appears.
- Confirm in Instruments that no timers stay active when the app is hidden and that idle usage meets the target.

Real notarization requires Apple credentials, so it cannot be completed in CI or on a fresh machine without configuring the Keychain profile.
