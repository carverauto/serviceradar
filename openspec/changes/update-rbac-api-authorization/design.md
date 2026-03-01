## Context
This branch added RBAC policy management and expanded authentication features in `elixir/web-ng/` and `elixir/serviceradar_core/`. The system now has multiple request entrypoints with different auth mechanisms:

- Browser + session access tokens (`elixir/web-ng/lib/serviceradar_web_ng_web/router.ex` `:browser` / `:api_auth` pipelines).
- API key / bearer-token auth for CLI and automation (`:api_key_auth` pipeline using `ServiceRadarWebNGWeb.Plugs.ApiAuth`).
- Token-gated download endpoints (`:api_token_auth` / public `/api` endpoints) that validate download tokens in-request.

Several modules currently default to `SystemActor.system/1` or accept any Guardian JWT token type. Combined, these patterns create RBAC bypasses for admin APIs and LiveViews.

## Goals / Non-Goals
- Goals:
- Prevent privilege escalation caused by implicit SystemActor defaults in user-facing code paths.
- Enforce token types for API authentication (for example, password reset tokens MUST NOT authenticate to admin APIs).
- Require explicit RBAC permissions for admin APIs and admin LiveViews (not just "logged in").
- Ensure Ash policy checks see a consistent actor shape (including role profile permissions) across pipelines.
- Keep token-gated download flows working without introducing session requirements.

- Non-Goals:
- Migrating the auth stack to AshAuthentication.
- Rewriting all existing Ash policies across the platform.
- Removing every `authorize_if always()` across the repo (only those that create user-reachable bypasses or unsafe defaults).

## Decisions
- Decision: Enforce Guardian `token_type` during API auth.
  Rationale: `ServiceRadarWebNGWeb.Plugs.ApiAuth` must only accept bearer tokens intended for API access (`typ=access` or `typ=api`). Tokens intended for other flows (for example `typ=reset`) are single-purpose and must not provide general API access.

- Decision: Align ApiAuth actor shaping with `Router.set_ash_actor/2`.
  Rationale: Ash policies and Permit permissions should evaluate the same effective permission set regardless of whether the request is session-based or header-token-based. The actor map assigned by ApiAuth should include `role_profile_id` and computed permission keys.

- Decision: Remove implicit SystemActor fallback from edge onboarding context modules.
  Rationale: Defaulting to SystemActor in context modules makes it too easy for controllers/LiveViews to accidentally run privileged operations without authorization. Instead, require an explicit actor for user-facing operations and use explicit SystemActor only for internal/background flows.

- Decision: Gate admin LiveViews by RBAC permission (and enforce in handlers).
  Rationale: Router-level `require_authenticated_user` is not sufficient for `/admin/*`. Each admin surface that can mutate or expose privileged state must require a permission key (for example `settings.edge.manage`, `settings.jobs.manage`).

- Decision: Replace unconditional `authorize_if always()` used for schedulers with explicit internal checks.
  Rationale: `authorize_if always()` is indistinguishable from "any actor can do this action". Prefer `actor_attribute_equals(:role, :system)` by running schedulers/workers as SystemActor, or allow nil-actor only via `ServiceRadar.Policies.Checks.ActorIsNil`.

- Decision: Treat legacy static `X-API-Key` as deprecated for admin surfaces.
  Rationale: Static keys produce `%Scope{user: nil}` and do not represent a principal with RBAC permissions. Admin APIs and LiveViews should require a user or service-account actor.

## Risks / Trade-offs
- Breaking change risk: clients that currently (incorrectly) use reset tokens or legacy static keys to call admin endpoints will fail after hardening.
- Background job risk: tightening policies for scheduled actions can break AshOban triggers if they rely on missing actors; migration needs to ensure scheduled actions still run with an allowed internal actor/check.
- Operational risk: trusted proxy configuration for client IP extraction must match deployment topology; misconfiguration can change audit/rate-limit behavior.

## Migration Plan
1. Add logging and metrics around API auth failures for token type mismatches and legacy key usage.
2. Ship token type enforcement and explicit actor requirements behind a short-lived config flag if needed.
3. Deprecate legacy static keys for admin endpoints and document supported alternatives (ApiToken or OAuth client credentials).
4. Update internal schedulers/workers to use an explicit internal authorization strategy (SystemActor or ActorIsNil).
5. Add regression tests that cover the bypasses fixed by this change.

## Open Questions
- Should collector administration require `settings.edge.manage` or a new explicit permission key (for example `settings.collectors.manage`)?
- Should ApiToken `scope` (read/write/admin) be enforced as an additional constraint beyond RBAC permissions?
- For AshOban-triggered actions, is it preferable to ensure the scheduler passes SystemActor (so policies use `role=:system`), or to allow nil actor via `ActorIsNil`?

