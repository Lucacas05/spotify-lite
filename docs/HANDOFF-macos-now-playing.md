# Handoff: macOS Now Playing Integration

## Summary

- The cause is confirmed: librespot sends audio through CoreAudio, but SpotifyLite never registers itself as a system media player.
- Implement the pending bridge using [`MPNowPlayingInfoCenter`](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter) and [`MPRemoteCommandCenter`](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter).
- SpotifyLite should claim the system media controls only while librespot is running and the active Spotify device is `SpotifyLite`.
- Correct the README, which currently states incorrectly that the media keys already work.

## Implementation Changes

- Add an internal `NowPlayingBridge` and explicitly link `MediaPlayer.framework`.
- Publish the title, artists, album, duration, elapsed position, high-resolution artwork, media type, playback rate, and playback state.
- Update `playbackState` and `MPNowPlayingInfoPropertyPlaybackRate` whenever playback starts, pauses, changes tracks, or receives refreshed state from Spotify. macOS can interpolate progress between updates.
- Load and cache artwork asynchronously. Guard updates by track identity so an older request cannot replace the artwork for a newer track.
- Register handlers for `play`, `pause`, `togglePlayPause`, `previousTrack`, and `nextTrack`. Disable seek and all other unsupported commands.
- Add explicit `play()` and `pause()` operations to `PlayerStore`. System commands must not depend on toggling potentially stale state.
- Dispatch system commands to `PlayerStore` on `MainActor`, update the expected system playback state immediately, and reconcile it with Spotify's confirmed state afterward.
- When the active device is no longer SpotifyLite, the user logs out, or local playback stops, disable the commands, clear the metadata, and mark playback as stopped.
- Keep the existing foreground polling behavior. In the background, poll every 30 seconds only while the last confirmed active device is SpotifyLite; stop after detecting a transfer to another device.
- Update the documentation and mark the pending `NowPlayingBridge` work as complete.

## Internal Interfaces

- Add `NowPlayingSnapshot`, a testable representation of the current track, position, and playback state that does not depend on MediaPlayer.
- Add `NowPlayingCommand` with `play`, `pause`, `toggle`, `previous`, and `next` cases.
- Put a minimal abstraction around the system media center so metadata publication and command registration can be tested without mutating the real macOS singleton.
- Do not change external APIs, authentication, storage, or the librespot integration.

## Test and Acceptance Plan

- Add unit tests for playing and paused metadata, local-device eligibility, cleanup after a device transfer, background polling policy, and stale artwork protection.
- Use a fake media-center adapter to verify that each system command dispatches exactly one `PlayerStore` action and that commands are disabled outside local playback.
- Manually verify:
  - macOS Now Playing shows the title, artist, album, artwork, and progress.
  - The play/pause media key works while the app is focused, in the background, and with its window closed.
  - Previous and next change tracks and refresh the metadata.
  - An automatic track transition appears within approximately 30 seconds while the app is in the background.
  - Playback on a phone or another Spotify device does not cause SpotifyLite to claim the Mac's controls.
  - Logging out or stopping librespot removes SpotifyLite from Now Playing.
- Do not run `xcodebuild` after the changes, per the repository instructions. Leave the added tests ready for CI or later user execution.

## Assumptions and Defaults

- "Media keys" means the system previous, play/pause, and next events. Their physical keys vary by Mac model and the user's `Fn` settings.
- Changing playback position from Control Center is out of scope for this iteration.
- A maximum delay of approximately 30 seconds is acceptable for external playback changes while the app is in the background.
