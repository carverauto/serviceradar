# Change: Server-side local-login enforcement, per-account opt-in, and break-glass switch

## Why

SSO "enforcement" in web-ng is currently **cosmetic**. The only gate on password
login is the system-wide `AuthSettings.allow_password_fallback` flag, and it is read
**only in the sign-in LiveView** (`sign_in.ex`) to decide whether to render the
password form. The actual credential path —
`auth_controller.ex` `create/2` and `local_sign_in/2` → `User.authenticate/3` —
never consults the auth mode or the fallback flag, and the `/auth/local` page
bypasses the UI gate entirely. Anyone who POSTs valid credentials to
`/auth/sign-in` or `/auth/local/sign-in` is signed in **regardless of SSO mode**.

We need real, server-side enforcement of local-login vs SSO, a per-account opt-in
so individual accounts (e.g. the bootstrap admin) can keep password access while
everyone else is SSO-only, and an infra-level break-glass switch that recovers
access when AuthSettings/IdP is broken — without re-introducing a downgrade attack.

## What Changes

- **BREAKING (behavioral):** Password acceptance is now enforced server-side. In
  `active_sso`/`passive_proxy` mode, a valid password is accepted **only** for
  accounts with `local_login_enabled = true` (or under the env break-glass).
  In `password_only` mode behavior is unchanged.
- Add a per-account `local_login_enabled` boolean to `ServiceRadar.Identity.User`
  (default `false`, public). Local-account actions (`:create`,
  `:register_with_password`) set it `true`; SSO/JIT (`:provision_sso_user`) keep it
  `false`. New admin action `:set_local_login` (covered by existing auth-manage
  policy) and an admin UI toggle on the user detail page.
- Add `ServiceRadarWebNGWeb.Auth.LoginPolicy.local_login_allowed?/2` — the single
  server-side decision point — and call it after `User.authenticate` in both
  controller entry points. Bcrypt verification still runs first (uniform timing,
  no enumeration oracle). **Fail closed**: if AuthSettings can't be resolved and
  the break-glass env is off, local login is denied (treated as SSO-enforced) —
  the `get_mode` `:password_only`-on-error default is **not** used for accept.
- Add infra break-glass env `SERVICERADAR_AUTH_FORCE_LOCAL_LOGIN` (read in web-ng
  `runtime.exs`). It is checked **first** by `LoginPolicy` and always permits local
  login (still requires a valid password — not a bypass), forces the sign-in form to
  render, needs no DB read or IdP, logs a loud boot WARNING when active, and emits an
  audit event on each break-glass login. Optional `SERVICERADAR_AUTH_DISABLE_SSO`
  hides the SSO button. Wired through Helm (`webNg.auth.*`) and docker-compose.
- Retire `allow_password_fallback` as a **gating** mechanism: stop reading it for any
  access decision and remove its toggle from the authentication settings page.
  Transitional: keep the column this release; use it only in the backfill.
- Migration: add `local_login_enabled boolean not null default false` to
  `platform.ng_users` with an UP-only backfill that preserves current behavior so
  nobody is locked out.

## Impact

- Affected specs: `ash-authentication`
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/identity/user.ex` (attribute, actions, policy, code interface)
  - `elixir/serviceradar_core/priv/repo/migrations/*_add_user_local_login_enabled.exs` (new) + `priv/repo/baseline/platform_schema.sql`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/auth/login_policy.ex` (new)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/auth_controller.ex` (server-side enforcement)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/auth_live/sign_in.ex` (always-offer local affordance + break-glass)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/auth_user_live/show.ex` (per-user toggle)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/authentication_live.ex` (remove fallback toggle)
  - `elixir/web-ng/lib/serviceradar_web_ng/admin_api*.ex` + `controllers/api/user_controller.ex` (new action path)
  - `elixir/web-ng/config/{config.exs,runtime.exs}` (break-glass config)
  - `helm/serviceradar/templates/web.yaml`, `values.yaml`, `values-demo.yaml`, `docker-compose.yml`
</content>
</invoke>
