## 1. Data model (serviceradar_core)

- [x] 1.1 Add `local_login_enabled :boolean` attribute to `ServiceRadar.Identity.User` (allow_nil? false, default false, public? true)
- [x] 1.2 Force `local_login_enabled = true` in `:create` and `:register_with_password`
- [x] 1.3 Leave `:provision_sso_user` at default false
- [x] 1.4 Add `:set_local_login` update action accepting `[:local_login_enabled]`
- [x] 1.5 Add `:set_local_login` to `@admin_user_management_actions` (covered by `@auth_manage_check`)
- [x] 1.6 Add `define :set_local_login` to the code interface

## 2. Migration

- [x] 2.1 Ecto migration: add `local_login_enabled boolean not null default false` to `platform.ng_users`
- [x] 2.2 UP-only backfill preserving behavior (password set AND fallback effectively true)
- [x] 2.3 Update baseline `platform_schema.sql`

## 3. LoginPolicy (web-ng)

- [x] 3.1 New `ServiceRadarWebNGWeb.Auth.LoginPolicy` with `local_login_allowed?/2` (ordered)
- [x] 3.2 Break-glass + disable-sso helpers reading app config
- [x] 3.3 SSO redirect path helper for the deny path

## 4. Server-side enforcement (web-ng)

- [x] 4.1 Enforce in `AuthController.create/2` after `User.authenticate` (resolve settings fail-closed, deny → log + flash + redirect)
- [x] 4.2 Enforce in `AuthController.local_sign_in/2` likewise
- [x] 4.3 Break-glass audit event emitted on break-glass-permitted login

## 5. Break-glass config + infra

- [x] 5.1 web-ng `runtime.exs` reads `SERVICERADAR_AUTH_FORCE_LOCAL_LOGIN` / `SERVICERADAR_AUTH_DISABLE_SSO` into app config + boot WARNING when active
- [x] 5.2 `config.exs` default `:auth` config (off)
- [x] 5.3 Helm `web.yaml` env wired to `webNg.auth.forceLocalLogin` / `disableSso`
- [x] 5.4 `values.yaml` + `values-demo.yaml` defaults (off)
- [x] 5.5 docker-compose web-ng env with comment

## 6. UI

- [x] 6.1 `sign_in.ex`: in SSO modes always show SSO button + subtle "Sign in with a local password"; honor break-glass/disable-sso; `password_only` unchanged
- [x] 6.2 `auth_user_live/show.ex`: per-user local-login toggle in Security card → `set_local_login` via AdminApi
- [x] 6.3 Remove `allow_password_fallback` toggle from `authentication_live.ex`

## 7. AdminApi path for set_local_login

- [x] 7.1 New `set_user_local_login/3` callback + delegate in `AdminApi`
- [x] 7.2 `AdminApi.Local` impl via `:set_local_login` action
- [x] 7.3 `AdminApi.Http` impl + route + `UserController.set_local_login` + include `local_login_enabled` in JSON

## 8. Tests + verify

- [x] 8.1 `LoginPolicy` unit test: full matrix (env on/off × mode × flag × hashed_password nil)
- [x] 8.2 Auth controller server-side deny path test/coverage
- [x] 8.3 `MIX_ENV=test mix compile --warnings-as-errors` + `mix format` (core + web-ng)
</content>
