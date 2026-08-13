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
| Window hidden | `osascript -e 'tell application "System Events" to set visible of process "SpotifyLite" to false'` | ~0% CPU when *not* playing locally (~45 MB RAM). Local SpotifyLite playback may poll every 30 s. |
| During playback | Playing, window visible | Low single-digit CPU (0.5 s scrubber ticks + 5 s polling) |

Also confirm no leftover librespot after quit or after kill/relaunch:

```bash
pgrep -fl 'librespot.*--name SpotifyLite'
```

## Decisions applied to meet the target

- Playback polling runs every 5 s while playing and backs off to 30 s while idle. In the background it stops, except during local SpotifyLite playback, when it continues every 30 s so Now Playing can follow track changes.
- The seek-bar `TimelineView` is **removed from the view hierarchy** unless a track is playing and the user is not dragging. Pausing the schedule in place still left layout work in the graph. Tick interval is 0.5 s (time labels only change once per second; position is interpolated). Dragging uses local `@State`, not the timeline.
- librespot is launched under a stdin-pipe wrapper so the child dies when the parent exits (crash, SIGKILL, Xcode stop). Stale `--name SpotifyLite` processes for the same `--system-cache` are reaped on the next `start()`. The credential cache is not deleted.
- librespot starts on demand (explicit “Play on this Mac” or playback with no active device), not at sign-in. Its wrapper waits for process/pipe events without a polling loop.
- The menu bar icon is opt-in and disabled by default.
- Artwork cache reserves only 2 MB of RAM and keeps 50 MB on disk.
- Track lists page incrementally through one bottom sentinel. Rows do not own notification subscriptions or async native-view state writes, so `LazyVStack` can release off-screen rows.

## Last local measurement (hidden window)

Observed on 13 August 2026, after 12 seconds in the background, **before** the idle-CPU fix. Repeat the three-scenario protocol on the release Mac after this change:

```text
PID    %CPU MEM  STATE
12338  0.0  45M  sleeping
```

The measurement should be repeated with Instruments (Allocations + Time Profiler) on the machine used to prepare each release; consumption varies by macOS version and loaded content.
