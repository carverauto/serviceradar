## 1. API Authentication Hardening
- [x] 1.1 Update `web-ng/lib/serviceradar_web_ng_web/plugs/api_auth.ex` to verify Guardian bearer tokens with explicit `token_type` and accept only `access` and `api`.
- [x] 1.2 Ensure OAuth2 client credentials tokens are minted with a consistent API token type (and claims) that matches API auth expectations (`web-ng/lib/serviceradar_web_ng_web/controllers/oauth_controller.ex`).
- [x] 1.3 Fix Ash ApiToken lookup in ApiAuth to work as an authentication step (use explicit internal actor for lookup or another safe pattern) and keep revocation/expiry checks intact.
- [x] 1.4 Align ApiAuth actor shaping with `Router.set_ash_actor/2` by including `role_profile_id` and computed permission keys.
- [x] 1.5 Ensure admin-facing API routes reject `%Scope{user: nil}` and require a principal (user/service account) rather than a legacy static key.

## 2. Admin API Authorization (api_key_auth)
- [x] 2.1 Remove SystemActor execution from `web-ng/lib/serviceradar_web_ng_web/controllers/api/collector_controller.ex` for admin operations and enforce an explicit RBAC permission.
- [x] 2.2 Pass the authenticated actor through `web-ng/lib/serviceradar_web_ng_web/controllers/api/edge_controller.ex` list/get/events paths and enforce `settings.edge.manage`.
- [x] 2.3 Audit `web-ng/lib/serviceradar_web_ng_web/controllers/api/*.ex` under `:api_key_auth` to ensure each endpoint either:
- [x] 2.3.1 Enforces an RBAC permission, or
- [x] 2.3.2 Is strictly token-gated (download token / signed blob token) with no privileged side effects.
- [x] 2.4 Fix stale router action mapping for `CollectorController.account_status/2` (`web-ng/lib/serviceradar_web_ng_web/router.ex`).

## 3. Edge Onboarding Context Modules
- [x] 3.1 Remove implicit SystemActor fallback from `web-ng/lib/serviceradar_web_ng/edge/onboarding_packages.ex` for user-facing operations (`list/2`, `get/2`, `delete/2`, `revoke/2`, `deliver/3`), or require an explicit opt-in to system mode.
- [x] 3.2 Remove implicit SystemActor fallback from `web-ng/lib/serviceradar_web_ng/edge/onboarding_events.ex` for user-facing reads (`list_for_package/2`, `recent/1`).
- [x] 3.3 Update call sites to pass actor explicitly (controllers and LiveViews).

## 4. Admin UI RBAC Gating
- [x] 4.1 Gate `/admin/edge-packages*` LiveViews behind `settings.edge.manage` and ensure reads are performed as the user actor.
- [x] 4.2 Gate `/admin/jobs*` LiveViews behind `settings.jobs.manage` and enforce permission checks in `handle_event/3` (especially `trigger_job` in `web-ng/lib/serviceradar_web_ng_web/live/admin/job_live/show.ex`).
- [x] 4.3 Review other `/admin/*` LiveViews for appropriate gating (cluster, collectors, edge-sites) and align behavior with RBAC catalog keys.

## 5. Ash Policy Hardening (Targeted)
- [x] 5.1 Replace unconditional `authorize_if always()` in internal-only actions that are user-reachable or could become user-reachable with an explicit internal check (SystemActor or `ServiceRadar.Policies.Checks.ActorIsNil`).
- [x] 5.2 Add Ash `authorizers: [Ash.Policy.Authorizer]` and policies to Identity resources that are currently Permit-only (`elixir/serviceradar_core/lib/serviceradar/identity/user.ex`, `elixir/serviceradar_core/lib/serviceradar/identity/role_profile.ex`, `elixir/serviceradar_core/lib/serviceradar/identity/authorization_settings.ex`, `elixir/serviceradar_core/lib/serviceradar/identity/auth_settings.ex`).

## 6. Audit and Client IP Hardening
- [x] 6.1 Centralize client IP extraction using trusted proxy configuration (avoid direct `x-forwarded-for` parsing in controllers/plugs).
- [x] 6.2 Update audit log writers and rate limiters to use the hardened client IP.

## 7. Tests
- [x] 7.1 Add regression tests that ensure reset tokens cannot authenticate via ApiAuth.
- [x] 7.2 Add regression tests that ensure edge onboarding admin endpoints cannot execute as SystemActor and require `settings.edge.manage`.
- [x] 7.3 Add regression tests that ensure `/admin/jobs/:id` cannot trigger jobs without `settings.jobs.manage`.

## 8. Validation
- [x] 8.1 Run `openspec validate update-rbac-api-authorization --strict`.
- [ ] 8.2 Run `cd web-ng && mix test` and any targeted `elixir/serviceradar_core` tests affected by policy hardening.
