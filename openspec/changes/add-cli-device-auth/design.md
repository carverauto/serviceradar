# Design: Add CLI device-code auth endpoints

## Token shape: Guardian JWT (chosen)

The CLI's polling endpoint returns a Guardian-issued JWT with the same shape the existing OAuth `password` and `client_credentials` grants emit — `typ: "api"`, configurable scope claim, configurable TTL. The existing `ServiceRadarWebNGWeb.Plugs.ApiAuth` already validates that token shape end-to-end (see `validate_guardian_jwt/2` in `plugs/api_auth.ex`), so the new device-code flow contributes zero new validation paths to the API request hot loop.

Considered: minting a long-lived `ServiceRadar.Identity.ApiToken` row instead. Rejected because:

- ApiToken stores a SHA-256 hash and looks the token up on every request — cheaper than JWT verification but adds a DB round-trip we don't have today for OAuth-issued tokens.
- The CLI needs to emit a single bearer string. JWTs naturally carry their own scope + TTL claims; ApiTokens require a separate row to express the same.
- Revocation is solvable for JWTs by tracking the `jti` of issued sessions in a `CliSession` row (see below), rather than building a JWT revocation list from scratch.

## Revocation strategy

Two options, picking one in design rather than building both:

**Option A (chosen): JWT + jti denylist.** Each issued JWT carries a `jti` claim. We persist a `cli_sessions` table keyed on `jti` with status `(active | revoked | expired)`. The `ApiAuth` plug grows a post-verify check that rejects a JWT whose `jti` is in the denylist. Cost: one extra DB lookup per CLI-token request. Mitigation: ETS cache of revoked `jti`s, refreshed on revoke.

**Option B (rejected): rely on JWT TTL alone.** Tokens revoke themselves after 30 days. Simpler but the user can't revoke a leaked CLI token until it expires — that's a regression from the existing ApiToken UX where revoke is immediate.

## User code format

`XXXX-XXXX` from the alphabet `BCDFGHJKLMNPQRSTVWXZ` (20 characters, omits vowels and easily-confused letters like `0OI1`). 8 characters → 20^8 ≈ 2.56e10 codes. With a 15-minute expiry and rate-limited polling that's sufficient brute-force resistance for this surface.

## Verification URL shape

`verification_uri`: `${instance}/cli/auth/device`. The user pastes their code into the LiveView form.

`verification_uri_complete`: `${instance}/cli/auth/device?user_code=WDJB-MJHT`. The CLI prefers this for `--no-browser` log lines and for the `openBrowser()` call so the user lands on a pre-filled form.

## Polling cadence

- `interval: 5` seconds in the device response per RFC 8628 default.
- Server enforces minimum 5 s between polls per device_code; faster polls return `slow_down` and bump the recommended interval by 5 s.

## Rate limiting

New buckets in `ServiceRadarWebNGWeb.Auth.RateLimiter`:

- `cli_auth_device` — 10 / minute / client IP. Defends against farming user codes.
- `cli_auth_token` — 60 / minute / device_code (i.e. one specific device authorization). Lets the CLI poll on its 5 s default cadence with headroom; abuse triggers the standard 429.

## Happy-path sequence

1. CLI POSTs `/api/v1/cli/auth/device` with `client_id=serviceradar-cli`, `scope=dashboard.publish`.
2. Server inserts a `device_authorizations` row with status `pending`, `expires_at = now() + 15 min`. Returns `device_code`, `user_code`, both verification URIs, `expires_in: 900`, `interval: 5`.
3. CLI prints the verification URL, opens the browser at `verification_uri_complete`.
4. Browser hits `/cli/auth/device?user_code=...`. If unauthenticated, LiveView redirects to log-in with `return_to`. Otherwise renders an approval form pre-populated with the code, the requesting `client_id`, and the scope.
5. User clicks Approve. LiveView updates the row to `approved` and stamps the user.
6. CLI's next poll to `/api/v1/cli/auth/token` observes `approved`, calls `Guardian.create_api_token/2`, persists a `cli_sessions` row with the JWT's `jti`, returns `{access_token, token_type: "Bearer", expires_in, scope, user}`.
7. CLI persists the token to `~/.config/serviceradar/credentials.json`.

## Settings UI

The "CLI sessions" page renders one row per `cli_sessions` entry that is still active or whose `expires_at` is within the last 30 days (so users can confirm a recent revoke). Columns:

- Issuing client (`serviceradar-cli` for now; extensible for future CLI clients).
- Scope.
- Issued-at, last-used-at, expires-at.
- Status (Active / Revoked / Expired).
- Revoke button (active rows only).

Admin sees a "User" column and a global revoke. Filter by user, status.

## What gets returned to the CLI on success

```json
{
  "access_token": "<jwt>",
  "token_type": "Bearer",
  "expires_in": 2592000,
  "scope": "dashboard.publish",
  "user": {
    "id": "<uuid>",
    "email": "alice@example.com"
  }
}
```

This matches the shape the CLI's `runDeviceCodeFlow` already parses, including the optional `user` object that `auth status` surfaces.

## Migration

Single migration adds `device_authorizations` and `cli_sessions`. Both are deployment-scoped (search_path-isolated). No back-fill — every existing CLI session today was minted via the manual-token fallback into the existing `ApiToken` table; those keep working unchanged.
