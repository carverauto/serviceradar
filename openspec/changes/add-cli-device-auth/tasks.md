# Tasks: add-cli-device-auth

## 1. Ash resources + migration
- [ ] 1.1 Create `ServiceRadar.Identity.DeviceAuthorization` Ash resource at `elixir/serviceradar_core/lib/serviceradar/identity/device_authorization.ex` with attributes `device_code_hash`, `user_code`, `client_id`, `scope`, `status` (atom: `pending`/`approved`/`denied`/`expired`), `user_id`, `expires_at`, `interval_seconds`, `last_polled_at`, `created_at`. Actions: `create`, `read :by_user_code` (filter on `user_code` + `status == :pending`), `read :by_device_code_hash`, `update :approve` (sets `status` + `user_id`), `update :deny`, `update :record_poll`, `update :expire`.
- [ ] 1.2 Create `ServiceRadar.Identity.CliSession` Ash resource tracking issued JWT `jti`s. Attributes: `jti`, `device_authorization_id`, `user_id`, `client_id`, `scope`, `issued_at`, `expires_at`, `last_used_at`, `revoked_at`, `revoked_by`. Actions: `create`, `read :active`, `read :by_user`, `update :revoke`, `update :record_use`.
- [ ] 1.3 Add migration adding `device_authorizations` and `cli_sessions` tables, wired through the existing schema-isolated migration runner.
- [ ] 1.4 Add unit tests for both resources covering action authorization (system-actor bypass, user can read own sessions, admin can read all, user can revoke own sessions).

## 2. Rate limiting
- [ ] 2.1 Add `cli_auth_device` and `cli_auth_token` buckets to `ServiceRadarWebNGWeb.Auth.RateLimiter`. Use the same Hammer (or equivalent) backend the existing OAuth grants use.
- [ ] 2.2 Add unit tests for the new buckets.

## 3. Controller — `POST /api/v1/cli/auth/device`
- [ ] 3.1 Create `ServiceRadarWebNGWeb.CliAuthController` at `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/cli_auth_controller.ex` with a `device/2` action.
- [ ] 3.2 Validate `client_id` against the supported list (`["serviceradar-cli"]` initially); reject with `invalid_client` otherwise.
- [ ] 3.3 Generate `device_code` (32 random bytes, base64url) and `user_code` (`XXXX-XXXX` from `BCDFGHJKLMNPQRSTVWXZ`) — retry on user_code collision against active `pending` rows.
- [ ] 3.4 Insert a `DeviceAuthorization` row with `expires_at = now() + 15 min`, `interval_seconds: 5`, `status: :pending`. Hash the device_code with SHA-256 before storage.
- [ ] 3.5 Apply the `cli_auth_device` rate limit before insertion; return 429 with `retry_after` on limit hit.
- [ ] 3.6 Return RFC 8628 §3.2 response: `device_code`, `user_code`, `verification_uri`, `verification_uri_complete`, `expires_in: 900`, `interval: 5`.
- [ ] 3.7 Add controller tests covering happy path, rate limit, invalid client_id, and missing body params.

## 4. Controller — `POST /api/v1/cli/auth/token`
- [ ] 4.1 Add a `token/2` action to `CliAuthController`.
- [ ] 4.2 Reject any `grant_type` other than `urn:ietf:params:oauth:grant-type:device_code` with `unsupported_grant_type`.
- [ ] 4.3 Apply the `cli_auth_token` rate limit per device_code; return `slow_down` (RFC 8628 §3.5) on hit and bump the row's `interval_seconds` by 5 s.
- [ ] 4.4 Hash the supplied `device_code` and look up the row. Return RFC 8628 errors for missing (`invalid_grant`), expired (`expired_token`), denied (`access_denied`), and pending (`authorization_pending`).
- [ ] 4.5 On `approved`, call `ServiceRadarWebNG.Auth.Guardian.create_api_token/2` with `typ: "api"`, `scopes: parsed_scopes(scope)`, `ttl: {30, :day}`, and a fresh `jti`. Persist a `CliSession` row with the JWT's `jti`. Atomically transition the `DeviceAuthorization` row's `status` to consumed (`:approved` rows mark `last_polled_at`; we keep them for audit so admins can tie the session back to a device approval).
- [ ] 4.6 Return `{access_token, token_type: "Bearer", expires_in, scope, user: {id, email}}`.
- [ ] 4.7 Add controller tests for every RFC 8628 error code, the success path, the slow_down branch, and an idempotency check (re-poll after success returns the same JWT once and refuses subsequent calls — or always issues a fresh JWT; pick the simpler behavior in code review).

## 5. Approval LiveView — `/cli/auth/device`
- [ ] 5.1 Create `ServiceRadarWebNGWeb.CliDeviceAuthorizeLive` at `elixir/web-ng/lib/serviceradar_web_ng_web/live/cli_device_authorize_live.ex`.
- [ ] 5.2 Wire `:browser` pipe-through. If `current_scope.user` is `nil`, redirect to `~p"/users/log_in?return_to=/cli/auth/device?user_code=#{user_code}"`.
- [ ] 5.3 Render an approval form: read-only `user_code` input (pre-filled from query string when present), client display name (`ServiceRadar CLI`), scope summary, Approve button, Deny button.
- [ ] 5.4 On Approve, call `DeviceAuthorization.approve/2` with the user's id and the user_code. Show a success message with a link back to the Settings → CLI sessions page.
- [ ] 5.5 On Deny, call `DeviceAuthorization.deny/2`. Show a confirmation message; the polling CLI surfaces the denial as `access_denied`.
- [ ] 5.6 Add LiveView tests covering: redirect when unauthenticated, code-not-found surface, expired-code surface, approve happy path, deny happy path.

## 6. Token revocation
- [ ] 6.1 Extend `ApiAuth` plug to look up the JWT's `jti` in `CliSession` after Guardian verification. Reject if the row is `revoked` or `expired`.
- [ ] 6.2 Cache the revoked-jti set in ETS (or the existing in-process cache layer) with a 30 s TTL so the per-request cost is negligible. Invalidate the cache when `CliSession.revoke/2` runs.
- [ ] 6.3 Add a unit test that revokes a session and confirms a subsequent request with the issued JWT 401s.

## 7. Settings UI — CLI sessions page
- [ ] 7.1 Create `ServiceRadarWebNGWeb.Settings.CliSessionsLive` at `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/cli_sessions_live.ex`.
- [ ] 7.2 Render: client name, scope, issued-at, last-used-at, expires-at, status badge, Revoke button. Admin sees a "User" column and a "Filter by user" select.
- [ ] 7.3 Wire route under the existing settings scope.
- [ ] 7.4 Wire the "Pending CLI device approval" callout: if the user has any `DeviceAuthorization` rows with `status: :pending`, surface a banner linking to `/cli/auth/device`.
- [ ] 7.5 Add LiveView tests covering: list renders for current user, admin sees all, revoke flips status + invalidates cache, expired rows show in greyed state.

## 8. Cleanup worker
- [ ] 8.1 Add an Oban worker (or equivalent scheduled job) that runs daily and:
  - moves `pending` rows past their `expires_at` to `:expired`;
  - moves `approved` rows whose issuing JWT's `expires_at` has passed (looked up via the linked `CliSession`) to `:expired`;
  - hard-deletes rows in terminal status older than 90 days.
- [ ] 8.2 Add a unit test for each cleanup branch.

## 9. Router wiring
- [ ] 9.1 Add `POST /api/v1/cli/auth/device` and `POST /api/v1/cli/auth/token` routes under the `:api_token_auth` pipeline.
- [ ] 9.2 Add `live "/cli/auth/device"` route under the `:browser` pipeline (no auth required at the route level — the LiveView handles the redirect itself so the user doesn't lose the user_code on log-in).
- [ ] 9.3 Add the Settings → CLI sessions route under the existing settings live_session.

## 10. Documentation
- [ ] 10.1 Update `~/src/developer/priv/content/docs/v2/dashboard-sdk.md`: move the device-code endpoint contract from "specs the CLI targets" to "implemented by ServiceRadar". Keep the manual-token fallback paragraph for older instances.
- [ ] 10.2 Add a "Manage CLI sessions" subsection pointing at the Settings → CLI sessions page and screenshotting the approval prompt.

## 11. CLI side (verification only)
- [ ] 11.1 Verify the existing `runDeviceCodeFlow` in `js/cli/src/auth/login.ts` parses every RFC 8628 error code we emit (the CLI was written against the same contract; this is a sanity-check pass).
- [ ] 11.2 Add an end-to-end smoke test that runs `serviceradar-cli auth login` against a Phoenix test server stood up from `web-ng/test/support/conn_case.ex` (skip if the test server isn't bootable without the rest of the runtime). If too heavy, defer to CI.

## 12. Validation
- [ ] 12.1 Run `openspec validate add-cli-device-auth --strict`.
- [ ] 12.2 Run `mix test elixir/web-ng/test/serviceradar_web_ng_web/controllers/cli_auth_controller_test.exs` (and the LiveView tests) — full suite green.
- [ ] 12.3 Run an end-to-end manual test: spin up a local web-ng, run `serviceradar-cli auth login --instance http://localhost:4000`, confirm the browser opens, approve, observe `~/.config/serviceradar/credentials.json` populated, run `serviceradar-cli dashboard publish` (or any instance-touching command) and confirm the issued JWT validates.
