# Tasks: add-cli-device-auth

## 1. Ash resources + migration
- [x] 1.1 `ServiceRadar.Identity.DeviceAuthorization` at `elixir/serviceradar_core/lib/serviceradar/identity/device_authorization.ex`. Attributes: `device_code_hash`, `user_code`, `client_id`, `scope`, `status` (`:pending`/`:approved`/`:denied`/`:expired`), `user_id`, `expires_at`, `interval_seconds`, `last_polled_at`, `approved_at`. Actions: `create`, `by_user_code`, `by_device_code_hash`, `by_user`, `pending_active`, `pending_expired`, `approve(user_id)`, `deny`, `record_poll`, `slow_down`, `expire`, `destroy`. Identities `unique_user_code` + `unique_device_code_hash`.
- [x] 1.2 `ServiceRadar.Identity.CliSession` at `elixir/serviceradar_core/lib/serviceradar/identity/cli_session.ex`. JWT-id-keyed, attrs `jti`/`device_authorization_id`/`user_id`/`client_id`/`scope`/`status`/`issued_at`/`expires_at`/`last_used_at`/`last_used_ip`/`use_count`/`revoked_at`/`revoked_by`. Actions: `create`, `by_jti`, `active_by_user`, `active`, `expired_active`, `revoke(revoked_by)`, `record_use`, `mark_expired`, `destroy`.
- [x] 1.3 Migration `20260504170000_create_cli_device_auth_tables.exs` adds both tables under the `platform` schema with the supporting indexes (status+expires for the cleanup worker, user-id index, unique on device-code-hash + user-code).
- [x] 1.4 13 unit tests covering action surface, attribute constraints (status `one_of`, primary-key + non-public sensitive `device_code_hash`), identity declarations, and the `:create` / `:approve` / `:deny` / `:revoke` / `:mark_expired` changeset transitions. Pure changeset tests — DB-bound integration tests deferred to §12.8 / §13.2.

## 2. Rate limiting
- [x] 2.1 `cli_auth_device` and `cli_auth_token` buckets used directly via the existing `ServiceRadarWebNGWeb.Auth.RateLimiter` (which is bucket-name-agnostic — buckets are arbitrary strings with per-call `:limit` + `:window_seconds`). No limiter changes required.
- [ ] 2.2 Dedicated bucket-load tests deferred — the existing `RateLimiter` has its own test suite and the buckets are exercised by the controller-level integration tests in §12.8.

## 3. Controller — `POST /api/v1/cli/auth/device`
- [x] 3.1 `ServiceRadarWebNGWeb.CliAuthController.device/2` at `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/cli_auth_controller.ex`.
- [x] 3.2 `client_id` validated against `["serviceradar-cli"]`; mismatch → `400 invalid_client`.
- [x] 3.3 `device_code` from 32 random bytes, base64url-encoded; `user_code` `XXXX-XXXX` from `BCDFGHJKLMNPQRSTVWXZ`. 5-attempt retry on Ash unique-index collision.
- [x] 3.4 `DeviceAuthorization` row inserted with `expires_at = now() + 15 min`, `interval_seconds: 5`, `status: :pending`. SHA-256 hash stored, plaintext only flows back to the CLI.
- [x] 3.5 `cli_auth_device` rate limit at 10 / 60s / client IP applied before insertion; hit → `429` with `retry_after`.
- [x] 3.6 RFC 8628 §3.2 response (`device_code`, `user_code`, `verification_uri`, `verification_uri_complete`, `expires_in`, `interval`).
- [x] 3.7 `test/phoenix/controllers/cli_auth_controller_test.exs` — happy path returns RFC 8628 §3.2 payload + persists SHA-256 hash; invalid client_id → 400 `invalid_client`; scope outside allow-list → 400 `invalid_scope`; rate-limit at 11th request → 429; `cli_auth_enabled = false` → 503 `cli_auth_disabled`. 13/13 cases / 0 failures via the srql-fixtures CNPG cluster (the `srql-fixtures-db-tests` skill).

## 4. Controller — `POST /api/v1/cli/auth/token`
- [x] 4.1 `CliAuthController.token/2`.
- [x] 4.2 Non-`urn:ietf:params:oauth:grant-type:device_code` grant_type → `400 unsupported_grant_type`.
- [x] 4.3 `cli_auth_token` rate limit at 60 / 60s / device-code; hit → `400 slow_down` *and* `DeviceAuthorization.slow_down/1` bumps `interval_seconds` by 5 s.
- [x] 4.4 Lookup by hashed device code; missing → `400 invalid_grant`, expired → `400 expired_token` (also flips row to `:expired`), denied → `400 access_denied`, pending → `400 authorization_pending`.
- [x] 4.5 On `:approved`, mint JWT via `Guardian.create_api_token(user, scopes:, ttl: {cli_session_ttl_days, :day})` and persist a `CliSession` row keyed on the JWT's `jti`. Approved row is left in place (kept for audit; `last_polled_at` stamped via `record_poll`).
- [x] 4.6 Success response `{access_token, token_type: "Bearer", expires_in, scope, user: {id, email}}` matching the OAuth shape the CLI already parses.
- [x] 4.7 Same `cli_auth_controller_test.exs` covers the token endpoint: every RFC 8628 §3.5 error code (`unsupported_grant_type`, `invalid_request`, `invalid_grant`, `authorization_pending`, `access_denied`, `expired_token`); the success envelope with `access_token` / `token_type` / `expires_in` / `scope` / `user`; `cli_auth_enabled = false` 503 path on the token endpoint too.

## 5. Approval LiveView — `/cli/auth/device`
- [x] 5.1 `ServiceRadarWebNGWeb.CliDeviceAuthorizeLive` at `elixir/web-ng/lib/serviceradar_web_ng_web/live/cli_device_authorize_live.ex`.
- [x] 5.2 Wired under the `:authentication` `live_session` (uses `mount_current_scope`); on unauthenticated mount the LiveView itself redirects to `~p"/users/log-in?return_to=/cli/auth/device?user_code=..."` so the code stays pinned through log-in.
- [x] 5.3 Form state `:prompt` (no code typed yet) takes a manual user_code; `:pending` state renders client / scope / expires / Approve / Deny.
- [x] 5.4 Approve → `DeviceAuthorization.approve(row, user_id)`; success state shows the "you can close this tab" card.
- [x] 5.5 Deny → `DeviceAuthorization.deny(row)`; `:denied` confirmation card; the polling CLI surfaces `access_denied`.
- [x] 5.6 `test/phoenix/live/cli_device_authorize_live_test.exs` — unauthenticated visitor → log-in redirect with `return_to` preserving user_code; prompt form when no code; `:pending` shows Approve / Deny + client / scope / code; Approve transitions row to `:approved` with user_id stamped; Deny transitions to `:denied`; unknown code → `:unknown` error state; expired code → no Approve / Deny; viewer-role visitor → "your role does not allow CLI auth" callout in place of buttons. 8/8 cases / 0 failures.

## 6. Token revocation
- [x] 6.1 No `ApiAuth` plug change needed — Guardian's existing `verify_not_revoked/1` already calls `ServiceRadarWebNG.Auth.TokenRevocation.check_revoked/1` for every JWT. Revoking a CLI session inserts a `RevokedToken` row keyed on the JWT's `jti` via the `ServiceRadarWebNG.Auth.CliSessions` context, so the next API request bearing the JWT 401s.
- [x] 6.2 ETS cache + 30 s refresh + automatic invalidation on revoke is built into the existing `TokenRevocation` GenServer; we reuse it as-is.
- [x] 6.3 `test/phoenix/live/cli_sessions_live_test.exs` — Revoke flips `cli_sessions.status` to `:revoked` AND writes a `RevokedToken` row, so `TokenRevocation.check_revoked/1` then returns `{:error, :revoked}` for the issued JWT. End-to-end revoke pipeline validated without re-implementing it.

## 7. Settings UI — CLI sessions page
- [x] 7.1 `ServiceRadarWebNGWeb.Settings.CliSessionsLive` at `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/cli_sessions_live.ex`.
- [x] 7.2 Renders client name, scope, issued / last-used / expires, status badge, and a Revoke button on active rows. Permission-gated: `cli.session.read_any` shows the User column + every user's rows; `cli.session.read_own` shows only the user's rows; without either, the list is empty. Server-side `ensure_can_revoke/2` enforces revoke perms before firing.
- [x] 7.3 Route `live "/settings/cli-sessions"` added under the existing `:require_authenticated_user_with_permit` `live_session`.
- [ ] 7.4 "Pending CLI device approval" callout banner deferred — current Settings page is read-only over `cli_sessions`; pending `device_authorizations` are surfaced via the verification URL instead.
- [x] 7.5 Same `cli_sessions_live_test.exs` — non-admin sees only own rows + no User column + other user's `jti` absent from the rendered HTML; admin sees every user's sessions with the User column visible; admin can revoke another user's session. 4/4 cases / 0 failures.

## 8. Cleanup worker
- [x] 8.1 `ServiceRadar.Identity.CliAuthCleanupWorker` (Oban `:maintenance` queue, `unique` constraint, daily reschedule). Runs three jobs per invocation: pending-`DeviceAuthorization` past TTL → `:expired`, active-`CliSession` past TTL → `:expired`, hard-delete terminal rows older than 90 days (configurable via `:retention_days`). Wrapped in `ServiceRadar.Identity.CliAuthScheduler` (uses the existing `ServiceRadar.ObanEnsureScheduled` macro) and slotted into `ServiceRadar.Cluster.CoordinatorChildren` behind the `CLI_AUTH_SCHEDULER_ENABLED` env / `:cli_auth_scheduler_enabled` config toggle (default true).
- [x] 8.2 `test/phoenix/identity/cli_auth_cleanup_worker_test.exs` — pending DeviceAuthorization past TTL → `:expired` (vs. still-valid stays pending); active CliSession past JWT TTL → `:expired` (vs. still-valid stays active); terminal DeviceAuthorization > 90d → hard-deleted (vs. < 90d retained); terminal CliSession > 90d → hard-deleted (vs. < 90d retained). 8/8 cases / 0 failures. Drive-by fix surfaced by these tests: both resources' destroy actions were missing `primary? true`, which would have caused production destroy attempts to silently fail with `NoPrimaryAction` and leave terminal rows lingering forever.

## 9. Router wiring
- [x] 9.1 `POST /api/v1/cli/auth/device` and `POST /api/v1/cli/auth/token` routed under `:api_token_auth` (no session, no CSRF) next to the existing `/oauth/token`.
- [x] 9.2 `live "/cli/auth/device"` mounted under the public `:authentication` `live_session` so the redirect-to-log-in works without the route itself requiring auth — the LiveView handles the gate explicitly so the `return_to` URL is preserved.
- [x] 9.3 `live "/settings/cli-sessions"` and `live "/settings/cli-auth"` (admin policy) routed under the existing `:require_authenticated_user_with_permit` `live_session` next to `/settings/api-credentials`.

## 10. Documentation
- [x] 10.1 `~/src/developer/priv/content/docs/v2/dashboard-sdk.md` — "Device-code endpoint contract" reframed from "specs the CLI targets" to "implemented in `ServiceRadarWebNGWeb.CliAuthController`". The "Endpoint shape, but different paths" carve-out dropped (paths are now fixed). Manual-token fallback paragraph kept for older instances.
- [x] 10.2 Same doc adds a "Manage CLI sessions" subsection covering the Settings → CLI sessions page (revoke flow, JWT denylist hookup) and an "Admin policy" callout listing `cli_auth_enabled` / `cli_session_ttl_days` / `cli_allowed_scopes`. Six `cli.*` permissions surfaced in a default-roles table. Approval-prompt screenshots deferred to a later docs pass.

## 11. CLI side (verification only)
- [x] 11.1 Verified — the CLI's `runDeviceCodeFlow` in `js/cli/src/auth/login.ts` parses every RFC 8628 error code the new controller emits (`authorization_pending`, `slow_down`, `expired_token`, `access_denied`, `invalid_grant`); the contract was authored from the CLI side originally and the controller respects it. The 503 `cli_auth_disabled` branch routes through the existing `DEVICE_CODE_UNAVAILABLE` fallback path (the `runDeviceCodeFlow` 404-handler treats any failure-class response as fallback-eligible).
- [ ] 11.2 End-to-end smoke test deferred — folded into §13.3.

## 12. RBAC + admin policy
- [x] 12.1 New `cli` section in `ServiceRadar.Identity.RBAC.Catalog` with six permissions (`cli.session.create`, `cli.session.read_own`, `cli.session.revoke_own`, `cli.session.read_any`, `cli.session.revoke_any`, `cli.policy.manage`). Defaults: read/revoke_own at all roles, create at operators+admins, read_any/revoke_any/policy.manage at admins.
- [x] 12.2 `AuthorizationSettings` extended with `cli_auth_enabled` (boolean, default true), `cli_session_ttl_days` (integer 1..365, default 30), `cli_allowed_scopes` (`{:array, :string}`, default `["dashboard.publish"]`). Migration `20260504180000_add_cli_auth_authorization_settings.exs` adds the columns with proper PG defaults.
- [x] 12.3 `CliAuthController` reads `AuthorizationSettings.get_settings/1` on every request. `cli_auth_enabled = false` → `503 cli_auth_disabled` on both endpoints; scope outside `cli_allowed_scopes` → `400 invalid_scope`; `cli_session_ttl_days` drives the JWT TTL. Settings-read failure falls back to hardcoded defaults that match the migration so the freshly-installed instance still works before the row exists.
- [x] 12.4 `CliDeviceAuthorizeLive` checks `cli.session.create` on mount. Without the permission, the pending state still renders client + scope + expires (so the user sees what was requested) but the action area is replaced with an "ask an admin for cli.session.create" callout. The polling CLI keeps receiving `authorization_pending` until the row TTLs and observes `expired_token` — deliberately not `access_denied`, so the role-based refusal isn't leaked over the wire.
- [x] 12.5 Implicitly satisfied by the existing architecture — Guardian JWTs only encode the user resource + scope, and the `ApiAuth` plug recomputes `RBAC.permissions_for_user/1` on every request. A user whose role is downgraded after a CLI session was issued loses those permissions immediately on the next API call. The scope claim itself is bounded by `cli_allowed_scopes` (§12.3). No JWT-claim embedding required.
- [x] 12.6 `Settings.CliSessionsLive` rewritten from role-based gating to permission-based: `cli.session.read_any` drives the all-rows + User-column view, `cli.session.read_own` drives self-only, both absent → empty list. `cli.session.revoke_any` exposes Revoke on every row, `cli.session.revoke_own` only on own rows. Server-side `ensure_can_revoke/2` re-checks before the action fires.
- [x] 12.7 New `Settings.CliAuthPolicyLive` at `/settings/cli-auth` lets a user with `cli.policy.manage` toggle `cli_auth_enabled`, edit `cli_session_ttl_days`, and edit the `cli_allowed_scopes` list (textarea, one per line / whitespace / comma separated). Form posts to `AuthorizationSettings.update_settings/3` via a system actor; on permission failure the user is redirected to `/settings/profile` with an explanatory flash.
- [x] 12.8 RBAC paths covered across the four integration test files: `cli_auth_enabled = false` → 503 in `cli_auth_controller_test.exs`; scope outside `cli_allowed_scopes` → 400 same file; viewer-role refusal of Approve / Deny in `cli_device_authorize_live_test.exs`; `read_own` vs `read_any` rendering split + `revoke_any` cross-user revoke in `cli_sessions_live_test.exs`. The admin policy panel (§12.7) is exercised at compile/route level — its form state machine is small enough that the manual smoke (§13.3) covers it without dedicated cases.

## 13. Validation
- [x] 13.1 `openspec validate add-cli-device-auth --strict` passes.
- [x] 13.2 Combined `mix test test/phoenix/{controllers/cli_auth_controller,live/cli_device_authorize_live,live/cli_sessions_live,identity/cli_auth_cleanup_worker}_test.exs --include integration` against the srql-fixtures CNPG cluster: **33 tests, 0 failures**. Migration drive-by from this run: the FK in `20260504170000_create_cli_device_auth_tables.exs` was referencing `:users` instead of `:ng_users` and was fixed in the same commit (the FK now matches the schema's actual user table per `RevokedToken`'s migration).
- [ ] 13.3 End-to-end manual smoke pending — spin up local web-ng, run `serviceradar-cli auth login --instance http://localhost:4000`, observe the browser open + LiveView render + Approve → CLI receives JWT → `~/.config/serviceradar/credentials.json` populated → `serviceradar-cli dashboard publish` validates against the issued JWT.
