# Playback and queue QA

Manual test performed on 13 August 2026 with the authenticated Debug app and an active Spotify Connect device.

## Verified behavior

- Double-clicking a result starts the selected track.
- Play/Pause toggles and correctly reflects the state.
- `Play next` adds tracks to the queue in the order they were sent.
- The queue popover loads and updates Spotify's items.
- Next consumes the items added manually.

Flow tested:

1. Play `Instant Crush (feat. Julian Casablancas)`.
2. Add `One More Time`, `Lose Yourself to Dance`, and `Veridis Quo`.
3. Verify that same order in the queue.
4. Skip between tracks and resume playback.

## Outstanding issues

### P1 — Serialize playback commands and wait for confirmed state

When Next and Previous were pressed quickly, the bar still showed the previous track and the commands ended in a different state than expected. The code only waits 400 ms before refreshing and allows several concurrent commands.

Proposed implementation:

- Add a `commandInFlight` state and temporarily disable the affected controls.
- Serialize player commands in an actor or a dedicated queue.
- After a command, poll playback with a short backoff until the change is observed or a timeout is reached.
- Show discreet progress; if Spotify does not confirm the change, recover the real state and show an error.

This also addresses an official limitation: Spotify states that execution order is not guaranteed when combining `Add to Queue`, `Next`, `Previous`, and other Player endpoints.

### P1 — Define Previous behavior explicitly

From `Veridis Quo`, Previous did not return to `Lose Yourself to Dance`; Spotify went back to `Instant Crush` and stayed paused. The app currently delegates entirely to `POST /me/player/previous` and does not keep its own history.

Alternatives:

- Keep Spotify's native semantics. This stays consistent with the Connect device, but does not guarantee returning to the previous item in the manual queue.
- Keep local history and force `play(trackURI:)`. This gives deterministic control, but can replace Spotify's context/queue and desync if another device controls the session.

Recommendation: keep the official semantics and improve feedback/sync before inventing a parallel history.

### P2 — Distinguish the manual queue from context/autoplay

After the three manual items, Spotify returned several repeats of `Instant Crush`. `GET /me/player/queue` returns a single list and does not identify the origin of each item, so the current UI mixes the manual queue, context, and autoplay.

Possible improvement: locally mark URIs added from SpotifyLite and show an “Added from SpotifyLite” section. This marking would be approximate: it is lost on restart and can become stale if another device modifies the queue.

### P2 — Remove, reorder, or clear the queue

Not implemented. The official Web API only exposes queue reading and appending to the end; it has no endpoints to remove, reorder, or clear playback queue items.

Partial alternative: keep a local queue and replace playback with a URI list. The cost is high: it no longer faithfully represents the shared Spotify Connect queue and can overwrite the current context.

## Official references

- https://developer.spotify.com/documentation/web-api/reference/get-queue
- https://developer.spotify.com/documentation/web-api/reference/add-to-queue
- https://developer.spotify.com/documentation/web-api/reference/skip-users-playback-to-next-track
