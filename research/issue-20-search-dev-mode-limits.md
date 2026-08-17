# `GET /search` under Development Mode — what the API accepts today

Research for ticket #20, 16 August 2026. Sources are Spotify's own developer documentation, changelog and blog, checked on that date, plus a few third-party reports flagged as such. Nothing here was verified by running the app; every claim is tagged **documented**, **inferred** or **unverified**.

## Main finding

`limit ≤ 10` is no longer an undocumented quirk of new apps. Since **February 2026** it is the value published in the `GET /search` reference, and the wording makes it **per item type**, not a total across types. The reduction (50 → 10, default 20 → 5) is described in the changelog as a **Development Mode** change; Extended Quota Mode apps are explicitly untouched.

`offset` is unchanged and documented up to `1000`. Paging is the only official way to get past 10 results, and Spotify says so itself.

One wrinkle worth carrying into the design discussion: Spotify **postponed** the endpoint-access part of the migration for *pre-existing* Development Mode apps, so old and new Client IDs may not behave the same today. Details below.

## What the reference page says today (documented)

From the [Search for Item reference](https://developer.spotify.com/documentation/web-api/reference/search):

| Parameter | Value |
|---|---|
| `q` | Required. "Your search query. You can narrow down your search using field filters." |
| `type` | Required. "A comma-separated list of item types to search across. Search results include hits from all the specified item types." Allowed: `album`, `artist`, `playlist`, `track`, `show`, `episode`, `audiobook`. |
| `market` | ISO 3166-1 alpha-2. "If neither market or user country are provided, the content is considered unavailable for the client." A user access token's account country takes priority over the parameter. |
| `limit` | "The maximum number of results to return in each item type." Default `5`, range `0`–`10`. |
| `offset` | "The index of the first result to return. Use with limit to get the next page of search results." Default `0`, range `0`–`1000`. |
| `include_external` | `audio` only. |

Documented response codes on that page: 200, 401, 403, 429.

Three things follow directly from the wording:

- **The cap is per type, not total.** "in each item type" plus "Search results include hits from all the specified item types" means `type=track,album,artist&limit=10` is documented to return up to 10 of each — up to 30 objects in one request. (**documented** by the wording; **unverified** empirically against a dev-mode token.)
- **All seven types are still listed as allowed.** Nothing in the reference, the February 2026 changelog or the migration guide removes `album`, `artist`, `playlist`, `show`, `episode` or `audiobook` from search. Audiobooks carry their own market note: "Audiobooks are only available within the US, UK, Canada, Ireland, New Zealand and Australia markets."
- **The page never mentions quota modes.** The `0–10` range is presented unconditionally, as if it applied to every app, even though the migration guide says extended-quota apps keep 50. The reference is documenting the restricted variant.

### Field filters still available in `q` (documented)

Also on the reference page, and relevant if the app ever wants sharper queries without more results per page:

> The available filters are `album`, `artist`, `track`, `year`, `upc`, `tag:hipster`, `tag:new`, `isrc`, and `genre`. Each field filter only applies to certain result types.

`artist` and `year` work on albums, artists and tracks; `album` on albums and tracks; `genre` on artists and tracks; `isrc` and `track` on tracks; `upc`, `tag:new` and `tag:hipster` only on albums. A `year` range is allowed (`year:1955-1960`).

## When and why the limit changed (documented)

The [February 2026 changelog](https://developer.spotify.com/documentation/web-api/references/changes/february-2026) records, for `GET /search`:

> [CHANGED] Search for Item (GET /search) – The `limit` parameter maximum value has been reduced from 50 to 10, and the default value has been changed from 20 to 5.

The [February 2026 migration guide](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide) states who is affected:

> **Extended Quota Mode apps**: No migration required. Apps in extended quota mode are not affected by any of the changes described in this guide — all existing endpoints, fields, and behaviors remain unchanged.
>
> **Development Mode apps**: This guide is for you.

| Date | What happens |
|---|---|
| February 11, 2026 | New Development Mode apps are created with new restrictions |
| March 9, 2026 | Existing Development Mode apps are migrated to new restrictions |

Its search section repeats the numbers (`limit` max 50 → 10, default 20 → 5) and gives the only official mitigation:

> If your app relies on fetching more than 10 results per search request, you will need to paginate through results using the `offset` parameter.

The migration checklist says the same: "Search pagination: Update search requests to handle the reduced limit maximum (10) and paginate if needed."

The rationale is in the blog post [Update on Developer Access and Platform Security](https://developer.spotify.com/blog/2026-02-06-update-on-developer-access-and-platform-security) (6 February 2026):

> Starting Wednesday, 11 February, all newly created Development Mode Client IDs will be created under the updated Development Mode rules and will have the following restrictions applied by default: Development Mode use will require a Spotify Premium account; Developers will be limited to one Development Mode Client ID; Each Client ID will be limited to up to five authorized users; API access will be limited to a smaller set of supported endpoints. From March 9, these same requirements will also apply to all existing Development Mode integrations.

Elsewhere the same post frames Development Mode as being for "learning, experimentation, and personal projects for non-commercial use by individual developers", and says it "should not be relied on as a foundation for building or scaling a business on Spotify".

This supersedes what `plan.md` recorded. The note at `plan.md` ~line 123 framed `limit ≤ 10` as a quirk of "apps in dev mode registered since 2025"; the actual cause is the February 2026 change.

## The March 9 postponement — the one live uncertainty (documented, with consequences inferred)

An update block appended to the same 6 February 2026 blog post says:

> **March 9: Postponed endpoint access changes for existing integrations** — After some review and feedback from the community, we have decided to postpone endpoint access changes for existing integrations. The Spotify Premium requirement, the authorized user cap and one Client ID per developer limit will take effect as planned for existing Development Mode integrations. We will share further details on updated timelines as soon as we're able to share more.

So the migration split into two groups:

- **Client IDs created on or after 11 February 2026**: full restricted endpoint set, `limit ≤ 10`.
- **Client IDs created before that**: Premium requirement, 5-user cap and Client-ID cap applied; endpoint-access changes deferred with no announced date.

Whether the `/search` `limit` reduction counts as an "endpoint access change" is **not stated**. (**unverified**.) The practical reading for SpotifyLite: since the app asks every user to register their own Client ID (map #1), the overwhelming majority of users will hold a post-February-2026 Client ID and will be capped at 10. Designing for anything looser would be designing for a grandfathered minority whose exemption Spotify has said it intends to end. (**inferred**.)

## Did anything change after February 2026? (documented)

Every later changelog was checked:

- [March 2026](https://developer.spotify.com/documentation/web-api/references/changes/march-2026): reversions only — `external_ids` restored on Album and Track. Nothing about search.
- [May 2026](https://developer.spotify.com/documentation/web-api/references/changes/may-2026): adds `account_id` to the User object. Nothing about search.
- [July 2026](https://developer.spotify.com/documentation/web-api/references/changes/july-2026) and the blog post [Web API quota updates for Development Mode](https://developer.spotify.com/blog/2026-07-23-web-api-quota-updates) (23 July 2026): Client IDs per developer raised from 1 to 25; **quota is now counted per developer account rather than per Client ID**, so all of one developer's dev-mode apps share the same quota buckets; the 429 body now carries `"reason": "QUOTA_EXCEEDED"`. Nothing about search.

**Conclusion: the search limits have not moved since February 2026.** As of 16 August 2026, `limit` max 10 / default 5 / `offset` 0–1000 is the current documented state.

## Offset and real reach (mixed)

- **Documented:** `offset` accepts `0`–`1000`. There is no separate dev-mode `offset` cap anywhere in the docs, the changelog or the migration guide, and the current reference page carries **no** combined `offset + limit ≤ 1000` note (older versions of the docs had one).
- **Inferred:** with `limit=10`, offsets `0…990` reach roughly 1000 results per type — the ceiling search has always had. February 2026 cut results *per request*, not total reachable depth; it costs ~100 requests instead of ~20 to walk the whole window.
- **Unverified:** whether a dev-mode token actually returns non-empty pages all the way to `offset=1000`; whether `offset + limit > 1000` returns `400` or is silently clamped; whether the per-type wording holds in practice for a multi-type request; whether a multi-type request costs one call or several against the rate limit. None of this is testable without running the app.
- **Historical noise (third-party, older):** community threads from 2023 reported `/search` returning empty `items` past roughly `offset=99`, reportedly fixed later. Treat as stale, but as a reason to verify paging depth empirically rather than assume 1000 works.

## Rate limits and quota (documented)

[Rate limits](https://developer.spotify.com/documentation/web-api/concepts/rate-limits):

> Spotify's API rate limit is calculated based on the number of calls that your app makes to Spotify in a rolling 30 second window. […] The limit varies depending on whether your app is in development mode or extended quota mode.

> Note that development mode apps also have quota restrictions which have a different enforcement mechanism than rate limits.

429 responses "will normally include a `Retry-After` header with a value in seconds". No numeric limit is published for either mode. The page also still recommends batch endpoints such as "Get Multiple Albums" — stale advice, since February 2026 removed them for Development Mode apps.

[Quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes):

> Spotify's Web API has a quota system that limits the number of requests made through development mode apps that belong to a single developer account. Note that this is different from rate limits. Endpoints are grouped into quota buckets and requests to endpoints in the same bucket count toward a shared limit. The specific groupings and limits are subject to change.

Also: up to 5 authenticated users; the owner needs Spotify Premium; a user who logs in without being allowlisted gets **403** on API calls. The page lists **no** per-endpoint or per-parameter differences between the two modes — that lives only in the February 2026 migration guide.

This is the real cost of paging: turning one search into ten requests to rebuild a 100-result page multiplies load against an undisclosed 30-second budget that, since July 2026, is shared across every dev-mode app of the same developer account.

## Is there an official route to broader search without a quota extension? (documented)

**No.** Excluding Extended Quota Mode, the documentation offers exactly one mechanism: `offset` pagination, as stated in the migration guide. There is no alternate endpoint, no scope, no header, no allowlist, and no published "supported endpoints for Development Mode" list — `concepts/apps` and the Web API landing page say nothing beyond "your app will be in Development Mode with limits on the number of users who can install it, and the number of API requests it can make".

Adjacent broad-discovery endpoints that could have substituted for a wider search were **removed** for Development Mode apps in February 2026:

- `GET /browse/new-releases`, `GET /browse/categories`, `GET /browse/categories/{id}`
- `GET /artists/{id}/top-tracks`
- `GET /markets`
- every batch fetch: `GET /tracks`, `/albums`, `/artists`, `/episodes`, `/shows`, `/audiobooks`, `/chapters` — "Fetch items individually instead."
- `GET /users/{id}`, `GET /users/{id}/playlists`

And an earlier wave had already gone, per [Introducing some changes to our Web API](https://developer.spotify.com/blog/2024-11-27-changes-to-the-web-api) (27 November 2024), which hit "Existing apps that are still in development mode without a pending extension request" and "New apps that are registered on or after today's date": Related Artists, Recommendations, Audio Features, Audio Analysis, Get Featured Playlists, Get Category's Playlists, 30-second preview URLs, and algorithmic / Spotify-owned editorial playlists.

Extended Quota Mode is out of scope for this project (map #1 decided one Client ID per user) and is closed to individuals anyway: since 15 May 2025 Spotify "only accepts applications from organizations (not individuals)", requiring a registered business, a launched service, "at least 250k MAUs", and a review that "can take up to six weeks". See [Updating the Criteria for Web API Extended Access](https://developer.spotify.com/blog/2025-04-15-updating-the-criteria-for-web-api-extended-access).

## Do album / artist / playlist searches actually work? (inferred + one third-party report)

- **Documented:** all seven `type` values remain allowed on the reference page, and no changelog entry removes any of them from `/search`.
- **Inferred:** `type=album,artist,playlist` should work with the same per-type cap of 10.
- **Unverified, third-party, cuts the other way:** [music-assistant/support#5360](https://github.com/music-assistant/support/issues/5360) (April 2026) reports that for a *dev-mode* Client ID, `GET /v1/search` came back empty for the queries powering their "Appears on" and "Versions" views, and attributes it to dev apps losing catalog access after the November 2024 changes. It is a single downstream diagnosis, not a reproducible curl, and it conflates several restrictions — but it is a reason to test album/artist searches empirically before building UI on them.
- Third-party corroboration of the February 2026 change list, useful as a cross-check on the docs: [ramsayleung/rspotify#550](https://github.com/ramsayleung/rspotify/issues/550) (11 February 2026) enumerates the same removed endpoints and renamed fields. It does **not** report any search type being blocked.

### Note on the community forum

Spotify runs an official staff-moderated mega-thread, [February 2026 Spotify for Developers update: thread](https://community.spotify.com/t5/Spotify-for-Developers/February-2026-Spotify-for-Developers-update-thread/td-p/7330564), which is where staff have been answering migration questions. `community.spotify.com` returns **403 to automated fetching**, so its contents could not be quoted first-hand here; search-engine excerpts indicate staff confirmed that the restrictions do not apply to extended quota clients, that `get_artist_albums` was marked deprecated in the docs **by mistake** and is not actually deprecated, and that playlist items are visible only for playlists the user owns or collaborates on. Treat all of that as **unverified** until read directly in a browser. No excerpt found staff discussing the search `limit` specifically.

## Also relevant to what search returns (documented)

The February 2026 field removals apply to every endpoint returning these objects, `/search` included:

- **Track**: `available_markets`, `linked_from`, `popularity` removed (`external_ids` reverted in March 2026).
- **Album**: `album_group`, `available_markets`, `label`, `popularity` removed (`external_ids` reverted).
- **Artist**: `followers`, `popularity` removed.

So results can no longer be re-ranked client-side by `popularity`, and track-relinking info (`linked_from`) is gone. The migration guide's own example suggests sorting by name instead.

## Current state of the code

Both call sites already sit at the ceiling:

- `SpotifyLite/Views/SearchView.swift:84-85` — `"search", query: ["q": trimmed, "type": "track", "limit": "10"]`
- `SpotifyLite/Views/CommandPaletteView.swift:245-246` — identical.

`SearchResponse` in `SpotifyLite/API/Models.swift:128-130` decodes only `tracks`, so adding `type=album,artist,playlist` means model work, not just a query-string change.

## Summary table

| Question | Answer | Status |
|---|---|---|
| `limit` max for Development Mode | 10 (default 5) | documented |
| Per type or total? | Per type — "in each item type" | documented (wording); unverified empirically |
| `offset` max | 1000, no combined `offset+limit` note | documented |
| Dev-mode-specific `offset` cap | None found in any doc | documented absence; unverified empirically |
| Allowed `type` values | album, artist, playlist, track, show, episode, audiobook | documented |
| Do album/artist/playlist searches work in dev mode? | Nothing removes them; one third-party report of empty results | inferred; unverified |
| Changed during 2025/2026? | Yes — February 2026 (50→10, 20→5); nothing since | documented |
| Do pre-Feb-2026 Client IDs get the old 50? | Endpoint-access changes postponed for existing integrations; unclear if `limit` is included | documented postponement; unverified scope |
| Official route to broader search without quota extension | Only `offset` pagination | documented |

## Sources

- [Search for Item — Web API reference](https://developer.spotify.com/documentation/web-api/reference/search)
- [Web API Changelog — February 2026](https://developer.spotify.com/documentation/web-api/references/changes/february-2026)
- [February 2026 Web API Dev Mode Changes — Migration Guide](https://developer.spotify.com/documentation/web-api/tutorials/february-2026-migration-guide)
- [Web API Changelog — March 2026](https://developer.spotify.com/documentation/web-api/references/changes/march-2026)
- [Web API Changelog — May 2026](https://developer.spotify.com/documentation/web-api/references/changes/may-2026)
- [Web API Changelog — July 2026](https://developer.spotify.com/documentation/web-api/references/changes/july-2026)
- [Update on Developer Access and Platform Security (6 Feb 2026, incl. the 9 Mar postponement update)](https://developer.spotify.com/blog/2026-02-06-update-on-developer-access-and-platform-security)
- [Web API quota updates for Development Mode (23 Jul 2026)](https://developer.spotify.com/blog/2026-07-23-web-api-quota-updates)
- [Updating the Criteria for Web API Extended Access (15 Apr 2025)](https://developer.spotify.com/blog/2025-04-15-updating-the-criteria-for-web-api-extended-access)
- [Introducing some changes to our Web API (27 Nov 2024)](https://developer.spotify.com/blog/2024-11-27-changes-to-the-web-api)
- [Quota modes](https://developer.spotify.com/documentation/web-api/concepts/quota-modes)
- [Rate limits](https://developer.spotify.com/documentation/web-api/concepts/rate-limits)
- [Apps](https://developer.spotify.com/documentation/web-api/concepts/apps)
- [February 2026 Spotify for Developers update: thread](https://community.spotify.com/t5/Spotify-for-Developers/February-2026-Spotify-for-Developers-update-thread/td-p/7330564) (staff thread; 403 to automated fetching, not quoted first-hand)
- Third party: [ramsayleung/rspotify#550](https://github.com/ramsayleung/rspotify/issues/550), [music-assistant/support#5360](https://github.com/music-assistant/support/issues/5360)
