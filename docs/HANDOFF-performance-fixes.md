# Handoff: SpotifyLite — fix idle resource usage

## Context

Project: `/Users/lucas/Documents/1 Projects/spotify` (native macOS SwiftUI app, `SpotifyLite.xcodeproj`, scheme `SpotifyLite`, branch `main`, clean tree at handoff time). Goal of the app: a lightweight Spotify client that uses close to zero resources when idle.

A resource inspection was just completed on the current `main` (HEAD `cf11ffb`). The user has asked for the fixes to be executed. Report language with the user: simple Peruvian Spanish, "tú". Commit messages: NO Co-Authored-By / Claude attribution lines (user's global rule).

## Findings from the inspection (measured, Release build)

1. **Main bug — ~15% CPU constantly at idle, even paused, even with the window hidden.**
   Cause confirmed via `sample`: `TimelineView(.periodic(from: .now, by: 0.2))` in `PlaybackScrubber`, `SpotifyLite/Views/PlayerBarView.swift:108`. It ticks 5×/s unconditionally and each tick drives a full `NSHostingView.layout()` pass. Introduced in commit `9cd4ba5` (seek bar). `PERFORMANCE.md` (repo root) documents 0.0% CPU hidden — now stale/wrong.

2. **Process leak — orphaned `librespot` children.**
   3 orphans were observed (~30 MB RAM each; they persist across app deaths). `SpotifyLiteApp.swift:19` stops librespot only on `NSApplication.willTerminateNotification`, which never fires on crash/SIGKILL/Xcode stop. Each new app run can stack another instance. Engine code: `SpotifyLite/Player/LibrespotEngine.swift` (launch args include `--system-cache …/Application Support/SpotifyLite/librespot`).

3. **Healthy (don't touch):** app memory 45–48 MB idle; polling of `/me/player` every 5 s correctly stops when scene inactive (`Views/MainWindow.swift:44-50`); URLCache capped 2 MB RAM / 50 MB disk; librespot idles at 0% CPU.

## Plan to execute

### Task 1 — Pause the scrubber timeline (the important fix)
In `PlayerBarView.swift` (`PlaybackScrubber`):
- Use a periodic schedule only while `player.state?.isPlaying == true` and a track exists; otherwise render statically (e.g. switch the `TimelineView` schedule, or wrap: static view when not playing).
- Consider lowering tick rate from 0.2 s → 0.5–1 s; time labels only change per second. Keep scrubbing (drag) fully responsive — scrub interaction uses local `@State`, not the timeline.
- Watch out: `PlaybackProgressState.progress(at:)` interpolates, so a 1 s tick still renders accurate positions.

### Task 2 — Bind librespot lifetime to the app
In `LibrespotEngine.swift`:
- On `start()`, detect and terminate stale `librespot` processes that were launched with `--name SpotifyLite` / pointing at the same `--system-cache` path before spawning a new one (e.g. `pgrep -f`).
- Also kill the 3 currently-running orphans once (`pkill -f 'librespot --name SpotifyLite'`) — verify nothing is playing first.
- Optional hardening: ensure the child dies with the parent (process group / kqueue EVFILT_PROC watchdog) if straightforward; otherwise the stale-cleanup on start is acceptable.

### Task 3 — Verify and update PERFORMANCE.md
- Rebuild Release:
  `xcodebuild -project SpotifyLite.xcodeproj -scheme SpotifyLite -configuration Release -sdk macosx CODE_SIGNING_ALLOWED=NO build`
  (DerivedData: `~/Library/Developer/Xcode/DerivedData/SpotifyLite-afgyxshroqgkquhhedvcaguhzokg/Build/Products/Release/SpotifyLite.app`)
- Measure idle CPU in three scenarios: window visible + nothing playing (this is where the regression lived — target ≤1%), window hidden, and during playback.
  `top -l 5 -s 3 -pid "$(pgrep -x SpotifyLite)" -stats pid,cpu,mem,state`
- Update `PERFORMANCE.md` with the new numbers and add the "visible, not playing" scenario to the measurement protocol.
- Run existing tests (`SpotifyLiteTests`) via `xcodebuild test` if the scheme supports it; `PlaybackProgressState` has test coverage worth keeping green.

## Success criteria
- Idle CPU (visible window, nothing playing): ~0–1% sustained.
- No librespot processes remain after the app exits or after repeated launch/kill cycles.
- Scrubber still updates smoothly during playback and while dragging.

## Suggested skills
- `mattpocock-skills:tdd` — for Task 1/2 if adding logic worth testing (e.g. schedule selection, stale-process detection).
- `run` — to launch the app and confirm the fix in the real app.
- `commit` — for the final commits (remember: no attribution lines).
- `mattpocock-skills:code-review` — optional review of the diff before committing.

## Notes / gotchas
- Spotify API dev-mode limits (from project memory): search limit ≤10; playlist tracks via `GET /playlists/{id}` (403 on `/tracks`).
- librespot auth uses its own OAuth cache (`credentials.json` in the system cache) — do not delete that directory when cleaning up processes.
- The DerivedData Release build can be stale; always rebuild before measuring (this bit the previous session).
