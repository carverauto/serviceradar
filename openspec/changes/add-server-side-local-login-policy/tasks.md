## 1. Data model (serviceradar_core)

- [ ] 1.1 Add `local_login_enabled :boolean` attribute to `ServiceRadar.Identity.User` (allow_nil? false, default false, public? true)
- [ ] 1.2 Force `local_login_enabled = true` in `:create` and `:register_with_password`
- [ ] 1.3 Leave `:provision_sso_user` at default false
- [ ] 1.4 Add `:set_local_login` update action accepting `[:local_login_enabled]`
- [ ] 1.5 Add `:set_local_login` to `@admin_user_management_actions` (covered by `@auth_manage_check`)
- [ ] 1.6 Add `define :set_local_login` to the code interface

## 2. Migration

- [ ] 2.1 Ecto migration: add `local_login_enabled boolean not null default false` to `platform.ng_users`
- [ ] 2.2 UP-only backfill preserving behavior (password set AND fallback effectively true)
- [ ] 2.3 Update baseline `platform_schema.sql`

## 3. LoginPolicy (web-ng)

- [ ] 3.1 New `ServiceRadarWebNGWeb.Auth.LoginPolicy` with `local_login_allowed?/2` (ordered)
- [ ] 3.2 Break-glass + disable-sso helpers reading app config
- [ ] 3.3 SSO redirect path helper for the deny path

## 4. Server-side enforcement (web-ng)

- [ ] 4.1 Enforce in `AuthController.create/2` after `User.authenticate` (resolve settings fail-closed, deny → log + flash + redirect)
- [ ] 4.2 Enforce in `AuthController.local_sign_in/2` likewise
- [ ] 4.3 Break-glass audit event emitted on break-glass-permitted login

## 5. Break-glass config + infra

- [ ] 5.1 web-ng `runtime.exs` reads `SERVICERADAR_AUTH_FORCE_LOCAL_LOGIN` / `SERVICERADAR_AUTH_DISABLE_SSO` into app config + boot WARNING when active
- [ ] 5.2 `config.exs` default `:auth` config (off)
- [ ] 5.3 Helm `web.yaml` env wired to `webNg.auth.forceLocalLogin` / `disableSso`
- [ ] 5.4 `values.yaml` + `values-demo.yaml` defaults (off)
- [ ] 5.5 docker-compose web-ng env with comment

## 6. UI

- [ ] 6.1 `sign_in.ex`: in SSO modes always show SSO button + subtle "Sign in with a local password"; honor break-glass/disable-sso; `password_only` unchanged
- [ ] 6.2 `auth_user_live/show.ex`: per-user local-login toggle in Security card → `set_local_login` via AdminApi
- [ ] 6.3 Remove `allow_password_fallback` toggle from `authentication_live.ex`

## 7. AdminApi path for set_local_login

- [ ] 7.1 New `set_user_local_login/3` callback + delegate in `AdminApi`
- [ ] 7.2 `AdminApi.Local` impl via `:set_local_login` action
- [ ] 7.3 `AdminApi.Http` impl + route + `UserController.set_local_login` + include `local_login_enabled` in JSON

## 8. Tests + verify

- [ ] 8.1 `LoginPolicy` unit test: full matrix (env on/off × mode × flag × hashed_password nil)
- [ ] 8.2 Auth controller server-side deny path test/coverage
- [ ] 8.3 `MIX_ENV=test mix compile --warnings-as-errors` + `mix format` (core + web-ng)
</content>
