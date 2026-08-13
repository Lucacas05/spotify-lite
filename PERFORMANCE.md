# Performance profile — Phase 3

Rebuild Release before measuring. DerivedData can be stale and that has produced false CPU readings:

```bash
xcodebuild -project SpotifyLite.xcodeproj -scheme SpotifyLite \
  -configuration Release -sdk macosx CODE_SIGNING_ALLOWED=NO build
open <DerivedData>/Build/Products/Release/SpotifyLite.app
```

Measure three scenarios with:

```bash
top -l 5 -s 3 -pid "$(pgrep -x SpotifyLite)" -stats pid,cpu,mem,state
```

| Scenario | How | Target |
|---|---|---|
| Window visible, nothing playing | Leave the window open, paused / no track | ≤ 1% CPU (this is where the 15% regression lived) |
| Window hidden | `osascript -e 'tell application "System Events" to set visible of process "SpotifyLite" to false'` | ~0% CPU, ~45 MB RAM |
| During playback | Playing, window visible | Low single-digit CPU (0.5 s scrubber ticks + 5 s polling) |

Also confirm no leftover librespot after quit or after kill/relaunch:

```bash
pgrep -fl 'librespot.*--name SpotifyLite'
```

## Decisions applied to meet the target

- Playback polling is cancelled when the scene is no longer active.
- The seek-bar `TimelineView` is **paused** unless a track is playing. Tick interval is 0.5 s (time labels only change once per second; position is interpolated). Dragging uses local `@State`, not the timeline.
- librespot is launched under a stdin-pipe wrapper so the child dies when the parent exits (crash, SIGKILL, Xcode stop). Stale `--name SpotifyLite` processes for the same `--system-cache` are reaped on the next `start()`. The credential cache is not deleted.
- The menu bar icon is opt-in and disabled by default.
- Artwork cache reserves only 2 MB of RAM and keeps 50 MB on disk.
- Lists use `LazyVStack`.

## Last local measurement (hidden window)

Observed on 13 August 2026, after 12 seconds in the background, **before** the idle-CPU fix. Repeat the three-scenario protocol on the release Mac after this change:

```text
PID    %CPU MEM  STATE
12338  0.0  45M  sleeping
```

The measurement should be repeated with Instruments (Allocations + Time Profiler) on the machine used to prepare each release; consumption varies by macOS version and loaded content.
