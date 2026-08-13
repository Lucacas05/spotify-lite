# Performance profile — Phase 3

Local measurement of the `Release` build on macOS, with the window hidden so `scenePhase != .active` and polling stops:

```bash
xcodebuild -project SpotifyLite.xcodeproj -scheme SpotifyLite \
  -configuration Release -sdk macosx CODE_SIGNING_ALLOWED=NO build
open <DerivedData>/Build/Products/Release/SpotifyLite.app
osascript -e 'tell application "System Events" to set visible of process "SpotifyLite" to false'
top -l 2 -s 3 -pid "$(pgrep -x SpotifyLite)" -stats pid,cpu,mem,state
```

Result observed on 13 August 2026, after 12 seconds in the background:

```text
PID    %CPU MEM  STATE
12338  0.0  45M  sleeping
```

Decisions applied to meet the target:

- Playback polling is cancelled when the scene is no longer active.
- The menu bar icon is opt-in and disabled by default.
- Artwork cache reserves only 2 MB of RAM and keeps 50 MB on disk.
- Lists use `LazyVStack`.

The measurement should be repeated with Instruments (Allocations + Time Profiler) on the machine used to prepare each release; consumption varies by macOS version and loaded content.
