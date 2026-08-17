# Findings: Sparkle 2 with Developer ID + Hardened Runtime, no sandbox — appcast, EdDSA signing, and what has to ship in the first DMG

Scope: facts and trade-offs for issue #25. No decision is made here.

Every claim is marked **[doc]** when it comes from a primary source (Sparkle's own documentation or source at tag `2.9.5`, Apple developer docs / man pages, docs.brew.sh, docs.github.com), **[test]** when it was verified locally in this repo, and **[inferred]** when it is a reasonable deduction that no source states outright.

---

## Short answer

Sparkle 2 in a **non-sandboxed** app with Hardened Runtime and Developer ID needs **no entitlements and no XPC services**. Those are sandbox-only concerns, and Sparkle's docs say so explicitly. What it does need is three things baked into the shipped build: an `SUFeedURL`, an `SUPublicEDKey`, and an incrementing `CFBundleVersion`. This is why the retrofit problem in the ticket is real: the first cohort's `.app` carries the public key and feed URL forever, and neither can be added after the fact for those users.

The current `scripts/release.sh` would need modest but non-optional changes: the signing step, the version step, and a new appcast/publish step. And `project.yml` cannot express the Sparkle keys today — verified by experiment below.

---

## 1. Entitlements: none needed

Sparkle's sandboxing guide opens by telling non-sandboxed apps to leave:

> "This guide shows how to use Sparkle 2 in sandboxed applications. If you do not sandbox your application, you should skip this guide unless you are interested in Removing the XPC Services."
> — [Sandboxing](https://sparkle-project.org/documentation/sandboxing/) **[doc]**

The customization page is equally blunt about the sandbox-related Info.plist knobs:

> "Here are the Info.plist settings relevant to use for Sandboxed applications using Sparkle 2. **Applications that are not sandboxed should not customize any of these settings.**"
> — [Customization](https://sparkle-project.org/documentation/customization/) **[doc]**

Specific entitlements often assumed to be required:

- `com.apple.security.cs.disable-library-validation` — **not needed for release**, and Sparkle actively steers you away from it. Library Validation is part of Hardened Runtime and stays **on**; it only breaks locally with an ad-hoc signature, because the framework's Team ID won't match:
  > "If you enable Library Validation, which is part of the Hardened Runtime and required for notarization, you will also need to either sign your application with an Apple Development certificate for development … or disable library validation for Debug configurations only. … **This is not an issue for distribution when you sign your application with a Developer ID certificate.**"
  > — [Sparkle documentation](https://sparkle-project.org/documentation/) **[doc]**

  Apple corroborates and warns against the escape hatch: "Because library validation is such an important security-hardening feature, Gatekeeper runs extra security checks on programs that have it disabled." — [disable-library-validation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation) **[doc]**

- `com.apple.security.cs.allow-jit` / `allow-unsigned-executable-memory` — **not mentioned anywhere** in Sparkle's docs. **[doc: absence]** Not required **[inferred]** — Sparkle's WebKit release-notes view runs in WebKit's own out-of-process content process, which carries its own entitlements.

- `com.apple.security.temporary-exception.mach-lookup.global-name` (values `$(PRODUCT_BUNDLE_IDENTIFIER)-spks` / `-spki`) — sandbox-only. **[doc]**

- `com.apple.security.get-task-allow` — Sparkle distributions before 2.4 shipped it; Xcode's Archive & Export strips it. If you hand-sign, make sure it's gone. **[doc]**

**Consequence for this repo:** SpotifyLite has no `.entitlements` file at all today (`project.yml` sets only `ENABLE_HARDENED_RUNTIME: YES` / `ENABLE_APP_SANDBOX: NO`). Adding Sparkle does not force one to be created. **[test]**

## 2. XPC services: not needed, optionally removable

Sparkle 2 ships two XPC services inside `Sparkle.framework`:

| Service | Path | When required |
|---|---|---|
| `Installer.xpc` | `Versions/B/XPCServices/Installer.xpc` | "required for Sandboxed applications" **[doc]** |
| `Downloader.xpc` | `Versions/B/XPCServices/Downloader.xpc` | "only needed for Sandboxed applications that do not request the `com.apple.security.network.client` … entitlement" **[doc]** |

Both are opt-in via Info.plist and default to `NO`. `SUEnableInstallerLauncherService`: "Do not enable this XPC Service if your application is not sandboxed." — [Customization](https://sparkle-project.org/documentation/customization/) **[doc]**

Removing them is a size optimization, not a requirement:

> "This section is optional and is for developers that want to trim down Sparkle. If you do not sandbox your application and thus do not enable Sparkle's XPC Services, you may choose to remove these services in a post install script when copying the framework to your application."
> — [Sandboxing](https://sparkle-project.org/documentation/sandboxing/) **[doc]**

**Load-bearing detail:** deleting anything inside the framework invalidates its signature. Sparkle's own removal script ends with a re-sign:

```bash
rm -rf "${SPARKLE_FRAMEWORK}/Versions/B/XPCServices/Downloader.xpc"
codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --preserve-metadata "$SPARKLE_FRAMEWORK"
```
**[doc]**

`Autoupdate` and `Updater.app` (also under `Versions/B/`) are the actual installer helpers — they are listed as things to **sign**, never as things to delete. **[doc]**

## 3. Code signing and `release.sh`

### The recommended path avoids hand-signing entirely

> "If you follow standard workflows and archive & export your application to Distribute your App, which we recommend, you do not need to especially do anything for signing Sparkle or its XPC Services and may skip this section."
> — [Sandboxing](https://sparkle-project.org/documentation/sandboxing/) **[doc]**

> "We recommend building your distributable app in Xcode by creating a Product › Archive and Distribute App choosing Developer ID method of distribution. Using Xcode's Archive Organizer will ensure Sparkle's helper tools are code signed properly for distribution. In automated environments, this process can be done using `xcodebuild archive` and `xcodebuild -exportArchive`."
> — [Sparkle documentation](https://sparkle-project.org/documentation/) **[doc]**

### The trap that applies directly to the current script

> "If you Code Sign on Copy Sparkle.framework, Xcode will re-sign Sparkle with your project's certificate but **will not re-sign the XPC Services and other helpers inside the framework**."
> — [Sandboxing](https://sparkle-project.org/documentation/sandboxing/) **[doc]**

`scripts/release.sh` today runs `xcodebuild archive` and then takes the `.app` **straight out of the archive** (`$ARCHIVE/Products/Applications/SpotifyLite.app`); it never runs `xcodebuild -exportArchive`. **[test]** That is precisely the "build + copy" shape that leaves nested helpers under-signed **[inferred]**, so with Sparkle the script would have to either add `-exportArchive` with a Developer ID export options plist, or sign the nested pieces itself.

### Sparkle's published hand-signing order (inside-out)

```bash
codesign -f -s "$CODE_SIGN_IDENTITY" -o runtime Sparkle.framework/Versions/B/XPCServices/Installer.xpc
# Sparkle >= 2.6
codesign -f -s "$CODE_SIGN_IDENTITY" -o runtime --preserve-metadata=entitlements Sparkle.framework/Versions/B/XPCServices/Downloader.xpc
codesign -f -s "$CODE_SIGN_IDENTITY" -o runtime Sparkle.framework/Versions/B/Autoupdate
codesign -f -s "$CODE_SIGN_IDENTITY" -o runtime Sparkle.framework/Versions/B/Updater.app
codesign -f -s "$CODE_SIGN_IDENTITY" -o runtime Sparkle.framework
```
**[doc]** — the `.app` is signed after all of these; `codesign(1)` requires it: "Code nested within bundle directories must already be signed or the signing operation will fail." **[doc]**

Notes:

- `-o runtime` goes on **every** nested binary, not only the app. Sparkle confirms Xcode's export "preserves the Hardened Runtime" for these helpers. **[doc]**
- Sparkle's example has **no `--timestamp`**. Notarization requires a secure timestamp on every signature, so it must be added **[inferred]** — Apple's "Resolving common notarization issues" page could not be quoted directly (JS-rendered), so treat this as **not established from a quote**.
- If `Downloader.xpc` is stripped, drop its line and use the `--preserve-metadata` re-sign from §2.

### `--deep`: forbidden for signing, fine for verifying

Sparkle:
> "Due to different code signing requirements, **please do not add `--deep` to `OTHER_CODE_SIGN_FLAGS` or from custom build scripts when signing your application. This is a common source of Sandboxing errors.**" **[doc]**

Apple, `codesign(1)`:
> "`--deep` **(DEPRECATED for signing as of macOS 13.0)** … All signing options will be applied, in turn, to all nested content. **This is almost never what you want.**" **[doc]**

For *verification* `--deep` is correct and is what Sparkle recommends: `codesign --deep --verify <path-to-app>` **[doc]**. The current script already verifies with `codesign --verify --deep --strict` **[test]**; Sparkle documents the `--deep --verify` form without `--strict` (**not established** whether `--strict` causes trouble).

### Archiving must preserve symlinks

> "Make sure symlinks are preserved when you create the archive. macOS frameworks use symlinks, and their code signature will be broken if your archival tool follows symlinks instead of archiving them."
> — [Publishing](https://sparkle-project.org/documentation/publishing/) **[doc]**

The script already uses `ditto -c -k --keepParent` for the notarization zip and `hdiutil` for the DMG **[test]**, both of which preserve symlinks **[inferred]**.

## 4. Info.plist keys — and why `project.yml` blocks them today

| Key | Type | Semantics (verbatim from [Customization](https://sparkle-project.org/documentation/customization/)) |
|---|---|---|
| `SUFeedURL` | String | "The URL of your appcast … It's recommended to set it in Info.plist, even if you change it later programmatically." |
| `SUPublicEDKey` | String | "The base64-encoded public EdDSA key. Use Sparkle's `generate_keys` tool to get it." |
| `SUEnableAutomaticChecks` | Bool | Unset → automatic checks start disabled and the user is prompted on second launch. `YES` → enabled without asking. `NO` → disabled without asking. |
| `SUScheduledCheckInterval` | Number | "The number of seconds between automatic update checks. The default is 86400 (1 day). … minimum bound of 1 hour". |
| `SUAutomaticallyUpdate` | Bool | Default `NO`. `YES` → download and install silently in the background. |
| `SUEnableInstallerLauncherService` | Bool | Default `NO`. **Leave unset** (sandbox only). |
| `SUEnableDownloaderService` | Bool | Default `NO`. **Leave unset** (sandbox only). |

All **[doc]**. Also mandatory: "your app bundle must have an incrementing and properly formatted `CFBundleVersion` key in your Info.plist. Sparkle uses this to compare and determine the latest version of your bundle." **[doc]**

Security-related keys worth knowing: `SUVerifyUpdateBeforeExtraction` (2.7.3+), `SURequireSignedFeed` (2.9+, requires the former), `SUAllowedURLSchemes`, `SUEnableJavaScript`. **[doc]**

Discipline note: "The Info.plist settings are meant for default configuration, while the runtime APIs are in response to user setting changes. **Please do not use the runtime APIs for setting initial default behavior.**" **[doc]**

### Repo-specific blocker, verified by experiment

`project.yml` uses `GENERATE_INFOPLIST_FILE: YES` and there is **no `.plist` file anywhere in the repo**. **[test]** Adding `INFOPLIST_KEY_SUFeedURL` / `INFOPLIST_KEY_SUPublicEDKey` to `settings.base` does **not** work: I built a minimal XcodeGen project with exactly those settings and the generated `Contents/Info.plist` contained neither key — Xcode silently drops `INFOPLIST_KEY_*` entries it does not recognize. **[test]**

XcodeGen's `info:` block does work. Same minimal project, rebuilt with:

```yaml
    info:
      path: SpotifyLite/Info.plist
      properties:
        SUFeedURL: "https://…/appcast.xml"
        SUPublicEDKey: "…"
    settings:
      base:
        GENERATE_INFOPLIST_FILE: NO
```

produced `SUFeedURL` and `SUPublicEDKey` in the built plist. **[test]** The cost is migrating the existing `INFOPLIST_KEY_LSApplicationCategoryType` and `INFOPLIST_KEY_NSHumanReadableCopyright` settings into that same `properties` map, and having a generated `Info.plist` in the tree.

Also relevant: `CURRENT_PROJECT_VERSION` is pinned at `1` and `MARKETING_VERSION` at `0.1.0`. **[test]** Sparkle compares `CFBundleVersion`, so the release process would have to start incrementing it per release.

## 5. EdDSA keys: where the private key lives

> "Run `./bin/generate_keys` … This needs to be done only once. … It will generate a private key and **save it in your login Keychain on your Mac**. … It will print your public key to embed into applications."
> — [Sparkle documentation](https://sparkle-project.org/documentation/) **[doc]**

The Keychain item is a generic password with service `https://sparkle-project.org` and account `ed25519` (default; `--account` overrides). **[doc: `generate_keys`/`generate_appcast` source @ 2.9.5]**

Backup and transfer:

> "Be sure to keep your keys safe and not lose them (**they will be erased if your keychain or system is erased**). You can use the `-x private-key-file` and `-f private-key-file` options to export and import the keys respectively when transferring keys to another Mac."
> — **[doc]**

`generate_keys -p` prints the existing public key at any time. **[doc]**

**If the private key is lost:**

> "If your keys are lost however, you can still sign new updates for Developer ID signed applications through key rotation." — and: "Sparkle allows rotating keys by issuing a new update that changes **either** your Apple code signing certificate **or** your EdDSA keys (but not both). For applications that opt into enabling `SUVerifyUpdateBeforeExtraction`, changing your EdDSA keys can only be done if the update archive is a Developer ID code signed disk image (dmg)."
> — **[doc]**

So Developer ID signing is the safety net that makes key loss recoverable rather than fatal. Note the interaction: enabling `SUVerifyUpdateBeforeExtraction` narrows rotation to signed-DMG archives.

Key hygiene, verbatim: "Please ensure your signing keys are kept safe and cannot be stolen if your web server is compromised. One way to ensure this for example is not having your signing keys accessible from the machine that is hosting your product." **[doc]**

Manual signing when needed: `./bin/sign_update path_to_your_update.(zip|dmg|tar.*)` emits `sparkle:edSignature="…" length="…"`. **[doc]** But: "Signatures are automatically generated when you make an appcast using `generate_appcast` tool. **This is the recommended method.**" **[doc]**

## 6. Appcast: hosting and generation

### Where it can live

Sparkle names no host. It only requires HTTPS:

> "Applications are by default **blocked from using HTTP** and will not be able to download any updates over HTTP." — "Make the appcast URL in Info.plist and download URLs in the appcast use HTTPS."
> — [App Transport Security](https://sparkle-project.org/documentation/app-transport-security/) **[doc]**

GitHub Pages (`appcast.xml`) + GitHub Releases (the `.dmg`) satisfies this for free, since both are HTTPS-only. Release limits: "Up to 1000 release assets may be associated with a single release. Each file included in a release must be under 2 GiB." — [About releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases) **[doc]**

GitHub does **not** publish an explicit stability guarantee for `https://github.com/{owner}/{repo}/releases/download/{tag}/{asset}` URLs, nor does it document the 302 to `objects.githubusercontent.com`. **[not established]** The URL is stable as long as the tag and filename are unchanged. **[inferred]** Sparkle has no documented statement about redirect handling either; it downloads via `NSURLSession`, which follows redirects by default. **[inferred]**

### The real friction: per-tag enclosure URLs

`generate_appcast` builds enclosure URLs from a single `--download-url-prefix`. With GitHub Releases each version's assets sit under a **different** tag path, so one prefix produces wrong URLs for every item but the current one. The appcast's enclosure URLs must be rewritten per item after generation. Upstream issues: [#1569](https://github.com/sparkle-project/Sparkle/issues/1569), [#648](https://github.com/sparkle-project/Sparkle/issues/648). **[doc]**

Rewriting is safe: the EdDSA signature covers the **archive bytes only** (`sign_update` takes just the archive as input), not the enclosure URL. **[inferred from the tool's interface]**

### Appcast item shape

```xml
<item>
    <title>Version 2.0 (2 bugs fixed; 3 new features)</title>
    <sparkle:version>2.0</sparkle:version>
    <sparkle:shortVersionString>2.0</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>14.0.0</sparkle:minimumSystemVersion>
    <pubDate>Mon, 05 Oct 2015 19:20:11 +0000</pubDate>
    <enclosure url="https://example.com/downloads/app.dmg"
               sparkle:edSignature="7cLA…Bw=="
               length="1623481"
               type="application/octet-stream" />
</item>
```
**[doc, Publishing]**

- `sparkle:version` = machine-readable `CFBundleVersion`; `sparkle:shortVersionString` = human-readable. Both are now recommended as top-level `<item>` children rather than enclosure attributes ("This is supported across all versions of Sparkle"). **[doc]**
- `sparkle:minimumSystemVersion` must be three-part (`major.minor.patch`). **[doc]**
- Release notes: either `<sparkle:releaseNotesLink>` or an embedded `<description><![CDATA[ … ]]></description>`; plain text via `sparkle:format="plain-text"` (2.4+), markdown via `sparkle:format="markdown"` (2.9 + macOS 12). **[doc]** Embedding avoids hosting a second file.
- `<sparkle:channel>` exists for betas (Sparkle 2 only): "By default, updaters only look for updates that are on the default channel" and "an updater cannot exclude itself from the default channel". **[doc]**

### `generate_appcast`

> "Generate appcast from a directory of Sparkle update archives." — `./bin/generate_appcast /path/to/your/updates_folder/` **[doc, @2.9.5]**

- Reuses and updates an existing appcast in that directory, or creates one. **[doc]**
- `.html`/`.md`/`.txt` files named after an archive become that item's release notes. **[doc]**
- Infers minimum OS and hardware requirements from the bundle. **[doc]**
- Prunes old items to `old_updates/`; `--maximum-versions` defaults to 3 per branch. **[doc]**
- **Does not support `.pkg` updates.** **[doc]**
- Signing: reads the private key from the Keychain by default; for CI, `--ed-key-file -` accepts the key on stdin (`echo "$PRIVATE_KEY_SECRET" | ./generate_appcast --ed-key-file -`). The old inline `-s <key>` form is rejected for newly generated keys. **[doc]**

### Delta updates: optional, automatic

> "The `./bin/generate_appcast` tool that comes with Sparkle automatically generates and signs delta updates."
> — [Delta updates](https://sparkle-project.org/documentation/delta-updates/) **[doc]**

`.delta` files are per-source-version, nested under `<sparkle:deltas>`; if the user's version has no delta, or patching fails, Sparkle falls back to the full archive. Default is 5 deltas per branch (`--maximum-deltas`). **[doc]** For GitHub Releases this means N extra assets per release, each needing the same per-tag URL rewrite.

### Archive format: DMG is first class

> "Put a copy of your .app (with the same name as the version it's replacing) in a .dmg, .zip, .tar.*, or .aar."
> — [Publishing](https://sparkle-project.org/documentation/publishing/) **[doc]**

For DMGs the doc recommends "APFS formatted images that use lzfse compression … for decent decompression speed" — the current script uses `-format UDZO` on an HFS+ image **[test]**, which still works but is not the tuned option. The only documented format-dependent branch in Sparkle's installer is app bundle vs `.pkg` found at the archive root. What the installer does specifically with a mounted DMG vs a ZIP is **not established** from the docs.

## 7. Integration: SwiftPM vs binary framework, and the zero-dependency principle

`plan.md:22` states the key decision "Zero third-party Swift packages — Smaller surface, smaller footprint". Sparkle is a framework either way, so **any** integration route breaks that principle as literally written. What differs is *how*.

| Route | What you get | Notes |
|---|---|---|
| **SwiftPM** (listed first in the docs) | `https://github.com/sparkle-project/Sparkle` | `Package.swift` @ 2.9.5 is a **single `.binaryTarget`** pointing at `Sparkle-for-Swift-Package-Manager.zip` from GitHub Releases, pinned by checksum. It is not source. **[doc]** The `bin/` tools land in the resolved artifact directory (`../artifacts/sparkle/Sparkle/bin/`), not your repo. **[doc]** The docs give explicit "Embed & Sign" steps for Carthage and Manual and **none** for SwiftPM; SPM binary targets are embedded and signed automatically **[inferred, not established from a quote]**. |
| **Manual binary framework** | Download `Sparkle.framework` from GitHub Releases, commit or vendor it | Drag in, set **Embed & Sign**, and set Runpath Search Paths to `@loader_path/../Frameworks` (Xcode's default `@executable_path/../Frameworks` "is already sufficient for regular applications"). **[doc]** |
| **Carthage** | `binary "https://sparkle-project.org/Carthage/Sparkle.json"` | Binary origin only: "Carthage strips necessary code signing information when building the project from source." Tools not included. **[doc]** |
| **CocoaPods** | — | Marked **`(deprecated)`** on the docs page. **[doc]** |

Framing for the trade-off: because the SwiftPM package is itself just a checksummed prebuilt XCFramework, the choice between "SwiftPM" and "vendored binary framework" is not source-vs-binary — it is *who fetches the same binary*. SwiftPM adds a `Package.resolved` and a network dependency at build time; vendoring adds ~megabytes to the git history but keeps the build hermetic. **[inferred]**

XcodeGen is not mentioned anywhere in Sparkle's docs. **[not established]** In `project.yml` it would be a `packages:` entry plus a `dependency: package: Sparkle`, with XcodeGen emitting the embed phase. **[inferred]**

Version facts: latest release **2.9.5** (2026-08-02), which carries a symlink-traversal fix in delta patching (#2891). Runtime minimum is **macOS 10.13** — well below this app's 14.0 target, so no deployment-target conflict. **[doc]**

---

## 8. Alternative A: Homebrew cask as the only update channel

Mechanically viable, but the gate is notability, not engineering.

The decisive stanza, verbatim from the [Cask Cookbook](https://docs.brew.sh/Cask-Cookbook):

> **`auto_updates`** — *(not required)* — "`true`. Asserts that the cask artifacts auto-update. Use if *Check for Updates…* or similar is present in an app menu, but not if it only opens a webpage and does not do the download and installation for you." **[doc]**

And from the [FAQ](https://docs.brew.sh/FAQ):

> "Casks for self-updating apps declare `auto_updates true`. … When Homebrew cannot make a reliable comparison, it normally skips the self-updating cask instead of guessing."
> "Casks that use `version :latest` have no version number to compare and are excluded from an ordinary `brew upgrade`." **[doc]**

So the two options are mutually shaping: **ship Sparkle → you must declare `auto_updates true` → brew stops upgrading the cask normally. Ship no in-app updater → omit the stanza, use a real version, and `brew upgrade --cask` replaces the app.** Users can force the other behavior with `--greedy-auto-updates` / `HOMEBREW_UPGRADE_GREEDY`, or opt out with `HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS=1`. **[doc]**

`livecheck` for a GitHub-Releases cask ([Brew Livecheck](https://docs.brew.sh/Brew-Livecheck)) **[doc]**:

```ruby
livecheck do
  url :url
  strategy :github_latest
end
```

`:github_latest` "should only be used if the upstream repository has a 'latest' release for a suitable version." Alternatives: `:git` against tags with `regex(/^v?(\d+(?:\.\d+)+)$/i)`, or `:page_match`. With no `livecheck` block at all, Homebrew "checks their `url` and `homepage` URLs, in that order." **[doc]**

**The binding constraint** — [Package Acceptance Policy](https://docs.brew.sh/Package-Acceptance-Policy), which [Acceptable Casks](https://docs.brew.sh/Acceptable-Casks) defers to:

> "at least 30 forks, 30 watchers or 75 stars."
> "at least **90 forks, 90 watchers or 225 stars for a self-submission by the repository owner**."
> "A code repository less than 30 days old is normally not eligible." **[doc]**

The self-submission tier is the one that applies here. Self-hosting the download is fine — "A cask must use a download published by the developer or by a distribution source the developer publicly endorses" **[doc]** — GitHub Releases under your own repo qualifies. There is no rule against it. Documented exceptions exist for established apps whose repo only hosts binaries, and for apps with "substantial, independently verifiable public interest". **[doc]**

Practical read: an own tap (`brew tap Lucacas05/spotify-lite`) has no notability gate at all **[inferred]**, but then discoverability is what you give up.

## 9. Alternative B: manual "Check for updates" against the GitHub API, no framework

- Endpoint: `GET /repos/{owner}/{repo}/releases/latest` — "The most recent non-prerelease, non-draft release, sorted by the `created_at` attribute." Auth is **not required** for public repos. — [Releases REST API](https://docs.github.com/en/rest/releases/releases?apiVersion=2022-11-28) **[doc]**
- Rate limit: "The primary rate limit for unauthenticated requests is **60 requests per hour**", "associated with the originating IP address". — [REST rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api) **[doc]**
- 60/hour per IP is ample per user, but the per-IP scoping means many users behind one NAT share it. Mitigations: cache and check at most once per launch or per day, or read a static `latest.json` from GitHub Pages, which has no API rate limit at all. **[inferred]**

What this route buys: preserves "zero third-party Swift packages" literally, adds no framework to sign, requires **no** change to the shipped-build contract beyond a URL that already exists — and critically, **it is not retrofit-hostile**: a first cohort with no updater at all can still be told about a new version by any later build, whereas Sparkle's `SUPublicEDKey` must already be in their bundle.

What it costs: it is a *notifier*, not an *installer*. The user downloads and drags the app themselves. Everything Sparkle does for free — signature verification of the update, atomic replacement, relaunch, deltas, staged/automatic background installs, release-notes UI — you either write or drop. **[inferred]**

---

## Trade-off summary

| | Sparkle 2 | Brew cask only | Manual check via GitHub API |
|---|---|---|---|
| Must ship in the **first** DMG | `SUPublicEDKey` + `SUFeedURL` + framework — **cannot be retrofitted for that cohort** | nothing | nothing (a URL is enough) |
| Zero-dependency principle | broken (binary framework, either route) | intact | intact |
| `release.sh` changes | sign nested helpers (or add `-exportArchive`), bump `CFBundleVersion`, run `generate_appcast`, rewrite enclosure URLs, upload appcast | add cask bump + `sha256` | none |
| `project.yml` changes | must move to an `info:` plist block; `INFOPLIST_KEY_*` does **not** work | none | none |
| New secret to protect forever | EdDSA private key in login Keychain (recoverable via Developer ID key rotation if lost) | none | none |
| Installs the update for the user | yes, including deltas and background installs | yes, via `brew upgrade --cask` | no — notify only |
| Reaches non-brew users | yes | no | yes |
| External gate | none | 90 forks / 90 watchers / 225 stars for self-submission | none |

Note the interlock worth deciding explicitly: **Sparkle and brew-cask-as-updater are not additive.** Declaring `auto_updates true` is required once a "Check for Updates…" menu item exists, and it takes the cask out of ordinary `brew upgrade`.

## Gaps (not established from primary sources)

- Whether `--timestamp` is strictly required on each nested `codesign` call for notarization — Apple's notarization-issues page is JS-rendered and could not be quoted.
- Whether `codesign --verify --deep --strict` (the form already in `release.sh`) behaves differently from Sparkle's documented `codesign --deep --verify` on a Sparkle-bearing bundle.
- Whether the SwiftPM route auto-generates the embed phase (Sparkle documents "Embed & Sign" only for Carthage and Manual).
- GitHub's stability guarantee for `releases/download/` URLs and its redirect to `objects.githubusercontent.com`.
- Sparkle's installer mechanics for a DMG archive specifically vs a ZIP.
- Sparkle's docs never mention XcodeGen.

## Sources

- [Sparkle 2 documentation (Basic Setup, security, integration)](https://sparkle-project.org/documentation/)
- [Sparkle — Sandboxing](https://sparkle-project.org/documentation/sandboxing/)
- [Sparkle — Customization (Info.plist keys)](https://sparkle-project.org/documentation/customization/)
- [Sparkle — Publishing an update](https://sparkle-project.org/documentation/publishing/)
- [Sparkle — Delta updates](https://sparkle-project.org/documentation/delta-updates/)
- [Sparkle — App Transport Security](https://sparkle-project.org/documentation/app-transport-security/)
- [Sparkle — Package updates](https://sparkle-project.org/documentation/package-updates/)
- [sparkle-project/Sparkle @ 2.9.5 — `Package.swift`, `generate_keys`, `generate_appcast`](https://github.com/sparkle-project/Sparkle)
- Sparkle issues [#1569](https://github.com/sparkle-project/Sparkle/issues/1569), [#648](https://github.com/sparkle-project/Sparkle/issues/648)
- [Apple — `com.apple.security.cs.disable-library-validation`](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)
- Apple — `codesign(1)` man page (local, macOS 26)
- [Homebrew — Cask Cookbook](https://docs.brew.sh/Cask-Cookbook), [Brew Livecheck](https://docs.brew.sh/Brew-Livecheck), [FAQ](https://docs.brew.sh/FAQ), [Acceptable Casks](https://docs.brew.sh/Acceptable-Casks), [Package Acceptance Policy](https://docs.brew.sh/Package-Acceptance-Policy)
- [GitHub — About releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases), [Releases REST API](https://docs.github.com/en/rest/releases/releases?apiVersion=2022-11-28), [REST rate limits](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)
- Repo: `RELEASE.md`, `scripts/release.sh`, `project.yml`, `plan.md`, `research/issue-4-macos-distribution.md`
