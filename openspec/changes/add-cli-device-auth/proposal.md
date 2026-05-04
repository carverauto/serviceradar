# Change: Add CLI device-code auth endpoints + settings UI

## Why

`@carverauto/serviceradar-cli` already ships `auth login` / `auth status` / `auth logout` end-to-end on the client. The CLI targets `POST /api/v1/cli/auth/device` and `POST /api/v1/cli/auth/token` per RFC 8628, and on a 404 it falls back to a manual-token paste so authors can still authenticate before the server side ships. Until the ServiceRadar API implements those endpoints, every developer using the CLI has to generate a long-lived token by hand in the Settings UI and paste it back into the terminal — a friction point that defeats the point of having a CLI auth flow in the first place.

This change implements the server-side surface so `serviceradar-cli auth login --instance https://serviceradar.example.com` opens the browser, the user signs in (via whatever auth they already have configured — local user, OIDC, OAuth), confirms a single approval prompt scoped to "ServiceRadar CLI", and the CLI receives a long-lived token without ever leaving the terminal. The token format is the same Guardian JWT the existing OAuth `password` and `client_credentials` grants issue (`typ: "api"`, configurable TTL, scopes claim), so the existing `ApiAuth` plug validates it without changes.

The Settings UI grows a "CLI sessions" page that mirrors the existing API-tokens page — admin and end-user can see each active CLI session (instance URL, scope, issued-at, last-used-at, expires-at) and revoke individual sessions. Approving a device request goes through the same UI surface so the user always sees what's about to be authorized.

PKCE-with-localhost-callback (`--web`) is **out of scope** for this change; the CLI defaults to device-code, and PKCE has its own follow-up. The endpoint contracts for both flows already live in the developer portal docs so the implementation order doesn't change the published contract.

## What Changes

### Server side (Elixir web-ng + serviceradar_core)
- **New Ash resource** `ServiceRadar.Identity.DeviceAuthorization` (capability: `cli-device-auth`). Stores `device_code_hash` (SHA-256), `user_code` (8-char dashed display code, e.g. `WDJB-MJHT`), `client_id`, `scope`, `status` (`pending` | `approved` | `denied` | `expired`), `user_id` (set on approve), `expires_at`, `interval_seconds`, `last_polled_at`, `created_at`. Migration adds the table to the deployment schema.
- **New Phoenix controller** `ServiceRadarWebNGWeb.CliAuthController` exposing:
  - `POST /api/v1/cli/auth/device` — accepts `client_id`, `scope`. Mints a device authorization, returns `{device_code, user_code, verification_uri, verification_uri_complete, expires_in, interval}` per RFC 8628 §3.2.
  - `POST /api/v1/cli/auth/token` — accepts `grant_type: urn:ietf:params:oauth:grant-type:device_code` and `device_code`. Returns `authorization_pending`, `slow_down`, `expired_token`, `access_denied` per RFC 8628 §3.5, or success with the same response shape as the existing OAuth endpoints (`{access_token, token_type, expires_in, scope, user}`).
  - Rate-limited via the existing `ServiceRadarWebNGWeb.Auth.RateLimiter` with new buckets `cli_auth_device` and `cli_auth_token`.
- **Approval flow page** at `/cli/auth/device` — Phoenix LiveView. If the user is not signed in, redirects to the existing log-in page with `return_to` set. Once authenticated, the page accepts a `user_code` (auto-filled from `verification_uri_complete` query param), shows the requesting client and scope, and exposes Approve / Deny buttons. Approve flips the matching `DeviceAuthorization` row to `approved` and stamps the user; Deny flips it to `denied`. The CLI's polling endpoint observes the new status.
- **Token issuance**: on first poll after `approved`, the controller calls `ServiceRadarWebNG.Auth.Guardian.create_api_token/2` with `typ: "api"`, `scopes: parsed_scopes`, `ttl: {30, :day}` (configurable), and a `cli_session_id` claim that points at the issuing `DeviceAuthorization` row. The plaintext token is returned exactly once. The `DeviceAuthorization` row stays around (status `approved`) so the Settings UI can list it and the user can revoke the issued JWT.
- **Token revocation**: a new `ServiceRadar.Identity.CliSession` Ash resource (or an extension to `DeviceAuthorization`) tracks the issued `jti` so revocation marks it consumed. The existing `ApiAuth` plug grows a quick post-verify check that rejects JWTs whose `jti` matches a revoked session. (Open question in design.md: do we add a `jti` denylist or rely on the existing JWT TTL + UI-driven token rotation?)
- **Cleanup**: an Oban worker purges expired `pending` rows daily and rolls `approved` rows to `expired` once their JWT TTL passes.
- **Router**: wire `:api_token_auth` (no session, just `accepts: ["json"]`) for the two endpoint pairs and `:browser` for the LiveView.

### Settings UI (Elixir web-ng LiveView)
- New "CLI sessions" page under Settings (parallel to "API tokens"). Lists every `cli_sessions` row belonging to the current user (admin sees everyone). Each row shows: client display name, scope, issued-at, last-used-at, expires-at, status (active / revoked / expired). Each row has a Revoke button.
- The existing "Authorize a CLI session" approval page (the LiveView under `/cli/auth/device`) is linked from the Settings → CLI sessions page so users can approve a code they typed into a terminal even if they didn't follow the verification URL.
- New "CLI authentication" admin panel (under the existing Authentication settings) lets admins toggle the device-code flow per-instance, set the issued-token TTL, and pin the allowed scope list. Disabling the flow makes `POST /api/v1/cli/auth/device` return `503 Service Unavailable` so the CLI falls back to manual-token paste.

### RBAC controls
- Add a new `cli` section to `ServiceRadar.Identity.RBAC.Catalog` exposing six permissions: `cli.session.create` (approve a device code), `cli.session.read_own`, `cli.session.revoke_own`, `cli.session.read_any` (admin), `cli.session.revoke_any` (admin), `cli.policy.manage` (admin). Default role assignments mirror the existing API-tokens permission set: operators+admins can create + manage their own; admins can read/revoke across users and toggle the policy.
- The `/cli/auth/device` approval LiveView checks `cli.session.create` before rendering the Approve button. A user without the permission sees a clear "your role does not allow CLI authentication; ask an admin" message and the polling CLI keeps receiving `authorization_pending` until the row expires (the LiveView never flips status without the permission).
- The `POST /api/v1/cli/auth/token` endpoint embeds the approving user's permission set into the issued JWT's claims so the resulting token can never grant capabilities the user themselves lacked at approval time. Revoking the user's `cli.session.create` permission later does **not** retroactively revoke active sessions — that's what the Settings → CLI sessions revoke button is for.
- The Settings → CLI sessions page is gated on `cli.session.read_own` (rendering own rows) and `cli.session.read_any` (rendering everyone's rows + the User column). Revoke buttons are gated on `cli.session.revoke_own` / `cli.session.revoke_any`.
- The "CLI authentication" admin panel is gated on `cli.policy.manage`.

### Documentation
- Move the device-code endpoint contract from "specs the CLI targets" to "implemented by ServiceRadar" in `~/src/developer/priv/content/docs/v2/dashboard-sdk.md`. The CLI-side fallback paragraph stays — instances on older ServiceRadar versions still need it.

## Impact

- **Affected specs**: `cli-device-auth` (new). The existing `ash-authentication` capability stays unchanged; CLI-issued JWTs validate through the same path as `password` / `client_credentials` grants.
- **Affected code**:
  - `elixir/serviceradar_core/lib/serviceradar/identity/device_authorization.ex` (new)
  - Migration adding `device_authorizations` table
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/cli_auth_controller.ex` (new)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/cli_device_authorize_live.ex` (new)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/cli_sessions_live.ex` (new)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex` (additions)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/auth/rate_limiter.ex` (new buckets)
- **CLI (no changes)**: the client side already targets these endpoints. Once the server lands, the manual-token fallback only fires on instances that haven't deployed it yet.
- **Compatibility**: Net-new endpoints. No existing API behavior changes. Existing `ApiAuth` plug already accepts the JWT shape we'll issue.
