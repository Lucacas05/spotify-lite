## Findings: App Sandbox, `Process`, notarization, and Homebrew Cask

### Short answer

**Yes, but not by default.** A macOS app with App Sandbox cannot freely execute `/opt/homebrew/bin/librespot` just by using `Process`. The child process inherits the parent's sandbox, and Apple states that only binaries inside the *static sandbox* can be executed; there is no dynamic equivalent for running any binary the user selects.

For an app distributed outside the Mac App Store, Apple does allow a temporary absolute-path exception to expand the static sandbox. That can make a known Homebrew install work, but it is fragile: there are arm64/Intel prefixes, `bin` symlinks into `Cellar`, versions, and library dependencies. In addition, `librespot` still inherits the sandbox, so its cache, network, and socket operations must be allowed.

Sources: [Apple: `Process`](https://developer.apple.com/documentation/foundation/process), [Apple DTS: executables from a sandboxed app](https://developer.apple.com/forums/thread/746478), [Apple DTS: file permissions](https://developer.apple.com/forums/thread/678819), [App Sandbox temporary exceptions](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html).

### Entitlements

To try a fixed path in a sandboxed build, the minimum set would conceptually be:

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
<key>com.apple.security.temporary-exception.files.absolute-path.read-only</key>
<array>
    <string>/opt/homebrew/opt/librespot/</string>
    <string>/usr/local/opt/librespot/</string>
</array>
```

The exception must cover the canonical path that is executed and the paths the process needs; it is not a good idea to open all of `/opt/homebrew/`. Use `network.server` only if `librespot` actually listens for incoming connections.

Points that are often confused:

- `com.apple.security.files.user-selected.read-only/read-write` grants dynamic access to chosen files, but does not grant executable access.
- `com.apple.security.files.user-selected.executable` allows creating unquarantined executable files; it is not the permission to launch an external binary.
- `com.apple.security.inherit` does not go on the main app. Apple documents it for an **embedded** helper target, together with `com.apple.security.app-sandbox`; that helper must carry exactly those two entitlements. An external child also inherits the parent's sandbox, so `inherit` does not expand `librespot`'s permissions. Sources: [Apple helper tool](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app) and [App Sandbox inheritance](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/EnablingAppSandbox.html).
- `com.apple.security.cs.disable-library-validation` is not needed to launch a separate process. It only applies when the host process loads third-party frameworks or plugins inside itself.

### Sandbox, Hardened Runtime, and notarization

- **App Sandbox:** limits files, network, hardware, and other resources. It is required to publish on the Mac App Store.
- **Hardened Runtime:** protects process integrity, and Apple requires it to notarize a macOS app.
- **Notarization:** automated review of software signed with Developer ID and issuance of a Gatekeeper ticket. It is not App Review and does not enable App Sandbox.

Sources: [Apple: App Sandbox](https://developer.apple.com/documentation/security/app-sandbox), [Apple: Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime), and [Apple: notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

That is why an app without App Sandbox **can** be distributed via a notarized DMG. Sign with `Developer ID Application`, enable Hardened Runtime, sign every executable you actually ship, use `notarytool`, staple with `stapler`, and validate with `codesign`/`spctl`. If `librespot` is external and installed by the user, SpotifyLite's notarization does not cover that binary: its signature, quarantine, architecture, and dependencies must be validated separately.

### Homebrew Cask

Homebrew Cask does not require App Sandbox. A cask installs prebuilt artifacts, usually from a `.dmg` or `.zip`, and can move the `.app` to `/Applications`. Its rules do require that the download come from the developer or a source they back, and that it does not force SIP or Gatekeeper to be disabled. The official tap's current audit checks signing and notarization of macOS artifacts: [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook), [Acceptable Casks](https://docs.brew.sh/Acceptable-Casks), and [Homebrew audit](https://github.com/Homebrew/brew/blob/main/Library/Homebrew/cask/audit.rb).

A custom cask could be:

```ruby
cask "spotify-lite" do
  version "0.1.0"
  sha256 "<dmg-sha256>"
  url "https://github.com/Lucacas05/spotify-lite/releases/download/v#{version}/SpotifyLite-#{version}.dmg"
  name "Spotify Lite"
  desc "Lightweight native Spotify player for macOS"
  homepage "https://github.com/Lucacas05/spotify-lite"

  app "SpotifyLite.app"
end
```

The cask installs the app; it should not assume it can install or run an arbitrary formula. For `librespot`, document `brew install librespot` as an optional dependency or embed your own copy. Homebrew normally classifies command-line-only software as a formula, not a cask.

### Concrete recommendation for SpotifyLite

1. Publish a universal arm64 + x86_64 build on GitHub Releases.
2. For the GitHub + DMG + brew distributed build, **disable App Sandbox**; keep Hardened Runtime + Developer ID + notarization.
3. In `PlayerEngine`, look explicitly for `/opt/homebrew/bin/librespot` and `/usr/local/bin/librespot`, validate that it is executable, and show a clear error if it is missing. Do not depend on a GUI app's `PATH`.
4. For a reproducible experience, my preference is to embed a signed universal `librespot` as part of the app and leave the user's Homebrew as an advanced option. If you want a sandboxed build or a future Mac App Store version, do not depend on the external binary: use the embedded helper or limit the app to remote control.

Trade-off: without App Sandbox you cannot submit that same build to the Mac App Store, and you increase the damage surface if the app has a vulnerability; in return, Homebrew integration is much simpler and more stable against sandbox restrictions. This is the macOS distribution part; the Spotify ToS risk associated with `librespot` is a separate topic.
