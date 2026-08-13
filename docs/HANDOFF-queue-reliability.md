# Handoff: Queue reliability and resource usage

## Context

SpotifyLite's playback queue was exercised in the running macOS app and then
traced through the SwiftUI and player-store implementation. The queue currently
looks editable, but it is only a snapshot returned by Spotify. Refreshing it,
starting playback, and double-clicking tracks can leave the popover out of sync
with the actual playback state. The app also continues to consume significant
CPU while playback is paused.

This document is the implementation plan. It does not authorize workarounds
that silently destroy or rebuild a user's Spotify queue.

## Verified findings

1. **Queue reordering is not implemented.** `QueueView` renders
   `player.queue.indices` in a `LazyVStack`; there is no move gesture, `onMove`,
   or player-store command that changes the order.
2. **The icon at the right of every queue row is not a drag handle.** It is the
   shared `TrackRow` "Play next" button. This is misleading inside the queue and
   can add a duplicate instead of moving the row.
3. **Spotify's Web API exposes queue read and append operations, not arbitrary
   reorder or removal.** The player API lists `GET /me/player/queue` and
   `POST /me/player/queue`, but no mutation endpoint for an existing queue.
   See the [Spotify Web API reference](https://developer.spotify.com/documentation/web-api).
4. **Playback and queue state are refreshed independently.** `PlayerStore.play`
   refreshes playback state after the command, but it does not refresh the
   queue. `QueueView` therefore continues to show a stale snapshot until its
   task or refresh button runs.
5. **Playing a row from the queue discards context.** The queue row calls
   `player.play(trackURI:)`. With no context URI, `PlayerStore` sends a one-item
   `uris` array. That starts an isolated track instead of preserving the
   playlist or queue semantics the UI implies.
6. **Refresh failures are destructive to the local snapshot.** `loadQueue()`
   replaces `queue` with an empty array on any error, so a transient API failure
   is presented as "The queue is empty."
7. **Concurrent loads can complete out of order.** Opening the popover, pressing
   refresh, and `playNext` can all call `loadQueue()`. Because the actor-isolated
   method suspends during the request, an older response can overwrite a newer
   one.
8. **The scrubber still drives layout work while paused.** Runtime sampling
   showed `TimelineView` updates and `NSHostingView.layout()` in paused state,
   with roughly 14-21% application CPU during the inspection. The current
   `paused:` schedule flag is not sufficient to remove the timeline from the
   SwiftUI graph.
9. **No refresh-specific memory leak was proven.** Memory remained roughly
   stable during the short reproduction. The verified performance problem is
   sustained view invalidation and layout work, not unbounded queue memory.

## Product decision

Treat the Spotify queue as **read-only upcoming playback** in this version.
Do not present drag affordances and do not emulate reordering by skipping many
tracks, appending duplicates, or replacing playback with a reconstructed URI
list. Those approaches are destructive, rate-limit-prone, lose context, or are
limited to the first 50 URIs.

If editable ordering becomes a requirement, design a separate local queue owned
by SpotifyLite. Users could reorder pending local entries before the app submits
them to Spotify. That is a new domain model and persistence feature, not a small
patch to `QueueView`.

## Implementation plan

### Phase 1 — Make queue state explicit and non-destructive

Introduce a queue snapshot in `PlayerStore` that distinguishes:

- the item reported as `currently_playing`;
- upcoming items from `response.queue`;
- loading state;
- the most recent refresh error;
- a monotonically increasing request generation or an owned refresh task.

Required behavior:

- Preserve the last successful snapshot when refresh fails.
- Expose the error separately so `QueueView` can show an inline warning without
  claiming the queue is empty.
- Ignore responses from superseded requests.
- Coalesce repeated refresh requests while one is already in flight, unless the
  caller explicitly requests a newer generation.
- Keep "not loaded," "loaded and empty," and "failed with cached data" as
  distinct states.

### Phase 2 — Synchronize queue after playback mutations

Create one player-store synchronization path for commands that can change queue
semantics:

- start playback;
- next and previous;
- add to queue;
- shuffle changes;
- playback transfer when the active device changes the reported queue.

After Spotify acknowledges the mutation, refresh playback and queue through the
same coordinator. Use a short, bounded propagation retry only when the returned
snapshot is demonstrably stale; do not add unconditional polling or multiple
independent sleeps to every view.

Views must call intent-level methods on `PlayerStore`; they must not each decide
when or how often to synchronize remote state.

### Phase 3 — Remove misleading queue interactions

Refactor `TrackRow` so its trailing action and activation behavior are explicit
instead of being shared accidentally by every list:

- Normal catalog and playlist rows keep double-click-to-play and "Play next."
- Queue rows do not show the "Play next" icon as a fake handle.
- Queue rows do not call `play(trackURI:)` on double-click.
- Queue rows remain keyboard selectable for inspection and accessibility.
- The popover explains that Spotify controls the order when appropriate.

Do not implement "skip to this item" by issuing `next` repeatedly. Besides being
slow and observable through the speakers, it can consume API quota and produce
partially applied state when a request fails.

### Phase 4 — Make refresh behavior visible and stable

Update `QueueView` so that:

- the refresh button is disabled or shows progress during the active request;
- cached rows remain visible during refresh;
- an empty state is shown only after a successful empty response;
- refresh errors appear inline and remain recoverable;
- opening and closing the popover does not create overlapping loads;
- row identity uses a stable track identity plus occurrence information rather
  than only the array index, because queues may legitimately contain duplicate
  tracks.

Avoid global implicit animation when replacing a snapshot. A queue refresh
should not animate unrelated player-bar or playlist layout.

### Phase 5 — Remove paused timeline work

Split the scrubber into two render paths:

- a static scrubber when nothing is playing, playback is paused, or the user is
  actively dragging;
- a timed scrubber that exists in the view hierarchy only during playback.

Do not rely solely on `TimelineView(.animation(..., paused: true))`. Removing the
timeline node in the static branch is the important architectural boundary.
Keep progress interpolation in `PlaybackProgressState`, and use the slowest tick
that still provides an acceptable progress display.

### Phase 6 — Tests and runtime verification

Add focused tests before changing behavior:

1. A failed queue refresh preserves the last successful snapshot.
2. A superseded response cannot overwrite a newer queue generation.
3. Repeated refresh intents result in one effective in-flight request.
4. Duplicate tracks retain distinct stable row identities.
5. Starting playback and `playNext` schedule playback/queue synchronization.
6. Queue-row activation cannot start isolated one-track playback.
7. The static scrubber path is selected whenever playback is paused.

Runtime verification in the app must cover:

- open and close the queue repeatedly;
- press refresh rapidly;
- double-click playlist tracks while the queue is open and closed;
- add the same track to the queue more than once;
- simulate an API failure while cached queue data exists;
- confirm VoiceOver names the trailing catalog action as "Play next" and does
  not announce a nonexistent reorder action in queue rows;
- profile visible/hidden and playing/paused states to confirm the timeline no
  longer performs sustained layout work while paused.

## Success criteria

- The queue never becomes empty merely because refresh failed.
- An older network response cannot replace newer queue state.
- Playback mutations converge to the same playback and queue snapshot without
  requiring a manual refresh.
- Queue rows contain no visual or accessibility affordance suggesting unsupported
  drag reordering.
- Double-clicking outside the queue preserves playlist context; queue rows do not
  start isolated playback.
- Paused CPU returns to the project's lightweight-client target and no paused
  `TimelineView` updates appear in a runtime sample.
- Memory remains bounded across repeated queue refreshes.

## Recommended delivery order

1. Queue state model and concurrency tests.
2. Playback/queue synchronization coordinator.
3. Queue-specific row interaction cleanup.
4. Refresh/error presentation.
5. Static versus timed scrubber rendering.
6. Accessibility pass and full runtime regression check.

Keep queue correctness and scrubber performance in separate commits when the
plan is implemented; they have different failure modes and rollback boundaries.
