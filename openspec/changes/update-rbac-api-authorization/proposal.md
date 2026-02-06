# Change: Harden RBAC and API Authorization (web-ng)

## Why
Recent RBAC and authentication work introduced multiple authorization bypass paths (SystemActor defaults, permissive JWT verification, and admin LiveView actions without permission checks). These gaps allow non-admin users or API-key callers to read or mutate admin-only resources and to authenticate to admin APIs using non-session tokens (for example, password reset tokens).

## What Changes
- Enforce token type and actor requirements in `ServiceRadarWebNGWeb.Plugs.ApiAuth` (only `typ=access` and `typ=api` bearer tokens for API authentication).
- Remove SystemActor execution from user-facing admin API controllers and require explicit permissions for each admin endpoint.
- Remove (or make explicit) "default SystemActor" fallbacks in edge onboarding context modules so user-facing calls cannot silently become system-privileged.
- Gate `/admin/*` LiveViews that mutate or expose admin-only state behind RBAC permissions (not just "logged in").
- Replace unconditional `authorize_if always()` patterns used for internal schedulers with explicit internal checks (nil actor via `ActorIsNil` or system actor), and document acceptable patterns.
- Harden client IP derivation used for audit/rate-limiting by restricting trust in `x-forwarded-for`.
- Fix stale routes that point at missing controller actions.

## Impact
- Affected specs: `ash-authentication`, `ash-authorization`, `edge-onboarding`, `job-scheduling`.
- Affected code: `web-ng/` API auth plug + `api_key_auth` controllers + admin LiveViews; `elixir/serviceradar_core/` policies for internal actions.
- **BREAKING**: password reset tokens and refresh tokens will no longer authenticate to API endpoints; legacy static `X-API-Key` behavior may be removed or restricted to eliminate "nil user" admin access.

## Findings (Security Review)

### Critical: Admin collector API executes as SystemActor (RBAC bypass)
`web-ng/lib/serviceradar_web_ng_web/controllers/api/collector_controller.ex:26` uses `SystemActor.system/1` for `/api/admin/collectors*` and `/api/admin/nats/credentials`, while `require_authenticated/1` only checks for `%Scope{}` and allows `%Scope{user: nil}`. This makes admin collector and NATS-credential operations reachable via API auth without RBAC enforcement.

### Critical: Edge onboarding list/get/events default to SystemActor (RBAC bypass)
`web-ng/lib/serviceradar_web_ng/edge/onboarding_packages.ex:46` and `web-ng/lib/serviceradar_web_ng/edge/onboarding_events.ex:35` default `opts[:actor]` to a system actor. The following call sites omit actor and therefore run as system:
- `web-ng/lib/serviceradar_web_ng_web/controllers/api/edge_controller.ex:50`
- `web-ng/lib/serviceradar_web_ng_web/live/admin/edge_package_live/index.ex:22`

### Critical: API auth accepts any Guardian token type (reset/refresh tokens usable as API auth)
`web-ng/lib/serviceradar_web_ng_web/plugs/api_auth.ex:102` calls `Guardian.verify_token(token, [])` without `token_type`, so any valid Guardian token type is accepted. Password reset tokens are issued as `typ=reset` (`web-ng/lib/serviceradar_web_ng_web/controllers/auth_controller.ex:154`) and should not authenticate to admin APIs.

### Critical: Job trigger is unauthenticated-by-permission in Admin Job show LiveView
`web-ng/lib/serviceradar_web_ng_web/live/admin/job_live/show.ex:92` triggers jobs without RBAC checks; the UI always renders a "Trigger Now" action (`web-ng/lib/serviceradar_web_ng_web/live/admin/job_live/show.ex:309`). This allows any logged-in user to enqueue admin jobs via `/admin/jobs/:id`.

### High: "Authenticated" checks often allow `%Scope{user: nil}` (legacy keys) and skip permission checks
Multiple controllers implement `require_authenticated/1` as `%Scope{}` presence (`web-ng/lib/serviceradar_web_ng_web/controllers/api/edge_controller.ex:479`, `web-ng/lib/serviceradar_web_ng_web/controllers/api/plugin_controller.ex:97`, `web-ng/lib/serviceradar_web_ng_web/controllers/api/plugin_assignment_controller.ex:102`). When combined with legacy static `X-API-Key` support (`web-ng/lib/serviceradar_web_ng_web/plugs/api_auth.ex:188`), this can unintentionally authorize read paths and, in the worst cases above, reach SystemActor code paths.

### High: ApiAuth actor shape is missing role profile permissions (inconsistent RBAC)
`web-ng/lib/serviceradar_web_ng_web/plugs/api_auth.ex:237` sets the Ash actor map without `role_profile_id` and without computed permission keys. RBAC evaluation then falls back to role defaults (`elixir/serviceradar_core/lib/serviceradar/identity/rbac.ex:36`), which can ignore custom role profiles and cause over-permission or under-permission depending on configuration.

### High: Ash ApiToken validation likely cannot succeed (no actor) and silently falls back to legacy keys
`web-ng/lib/serviceradar_web_ng_web/plugs/api_auth.ex:211` looks up `ServiceRadar.Identity.ApiToken` via `Ash.read/1` without an actor. `ServiceRadar.Identity.ApiToken` enforces policies (`elixir/serviceradar_core/lib/serviceradar/identity/api_token.ex:145`) and does not allow nil actors. ApiAuth treats lookup errors as not found and then attempts legacy static key validation, which increases the chance operators will rely on legacy keys instead of scoped API tokens.

### Medium: `x-forwarded-for` is trusted without proxy validation
Multiple files derive IP addresses from `x-forwarded-for` directly (for example `web-ng/lib/serviceradar_web_ng_web/plugs/api_auth.ex:172`, `web-ng/lib/serviceradar_web_ng_web/controllers/auth_controller.ex:127`). Without trusted-proxy enforcement this allows spoofing audit fields and bypassing IP-based throttles.

### Medium: Stale router action (DoS via 500)
`web-ng/lib/serviceradar_web_ng_web/router.ex:166` defines `GET /api/admin/nats/account` routed to `CollectorController.account_status/2`, but `CollectorController` has no such action. Hitting this route will raise at runtime.
