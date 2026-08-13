# Per-user Client ID onboarding — agreed design

Result of the grilling for ticket #5, 13 August 2026. Facts verified against Spotify documentation current as of that date.

## First launch

- App **explorable without setup**: sidebar visible, content area with a central "Get started" card that launches the wizard. No per-section empty states or mock data.
- The wizard **auto-opens on first launch** as a **sheet**, dismissible; if dismissed, the "Get started" CTA remains.
- No progress persistence: the wizard always starts at step 1, with the Client ID field pre-filled if one already exists.

## Wizard (multi-step, English only in v1)

1. **Create the app** in the [Developer Dashboard](https://developer.spotify.com/dashboard): button that opens the dashboard; instructions: name, description, check **Web API**, accept the Developer Terms. Note: the dashboard may require email verification before creating apps.
2. **Register the loopback redirect URI** `http://127.0.0.1:<port>/callback`, pre-written with a copy button. Warn that the match must be exact (casing, path, trailing slash). Context: since 2025 Spotify only documents `https://` and loopback as safe; `localhost` is no longer valid; custom schemes (what the original plan assumed with `spotifylite://callback`) remain "officially supported" but there are reports of `INVALID_CLIENT: Insecure redirect URI` on new clients. **Decision: loopback**, with an ephemeral local HTTP mini-server during login (dynamic ports have an exemption for loopback literals).
3. **Paste the Client ID**: trim whitespace, not empty. If it does not match `^[0-9a-f]{32}$` (observed format, no official regex), **yellow warning without blocking** — the test login is the final authority. Stored in **UserDefaults** (it is not a secret; tokens do go to the Keychain).
4. **Test login** (real OAuth PKCE). Onboarding is only marked complete when the flow returns tokens.

## Login-step errors → actionable messages

| Error | Wizard message |
|---|---|
| `INVALID_CLIENT: Invalid client` | The Client ID does not exist: check it and paste it again. |
| `Invalid redirect URI` / `Insecure redirect URI` | Go back to your app settings and add exactly this URI (copy button). |
| HTTP `403` "User not registered" | Your account is not registered in the dashboard app (Development Mode: 5 authenticated users per app; irrelevant if each user creates their own). |
| HTTP `429` `QUOTA_EXCEEDED` / Premium-related failures | The app owner needs active Premium; quota is shared across the account's Client IDs (max 25 per account since July 2026). |

Generic fallback with a troubleshooting link for any other error.

## Close

- "You're all set" screen with a button that closes the sheet and loads the library.
- On the final step, `GET /me` → if `product ≠ premium`: warning "Free account: browsing works, playback control won't", without blocking, plus a discreet persistent badge in the UI.
- Later reconfiguration via a **Settings panel** (editable field + "test login" + diagnostics), without reopening the wizard.
