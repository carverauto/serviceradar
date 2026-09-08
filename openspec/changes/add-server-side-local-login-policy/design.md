## Context

web-ng supports three auth modes via `AuthSettings.mode`: `password_only`,
`active_sso`, `passive_proxy`. The intended security posture is "when SSO is the
primary method, regular users must use SSO; only designated local accounts (and an
operator break-glass) may use a password." Today that posture is unenforced: the
credential path (`AuthController.create/2`, `AuthController.local_sign_in/2` →
`User.authenticate/3`) accepts any valid password regardless of mode. The
`allow_password_fallback` flag only hides the form in the LiveView; `/auth/local`
ignores even that.

## Goals / Non-Goals

- Goals:
  - Enforce local-login vs SSO **server-side**, at the credential acceptance point.
  - Per-account opt-in (`local_login_enabled`) so the bootstrap admin keeps password
    access while regular users are SSO-only.
  - An infra break-glass switch that recovers access when AuthSettings/IdP is broken,
    without a DB read or the IdP, and without enabling a downgrade attack.
  - Preserve current behavior on upgrade (no lockouts).
- Non-Goals:
  - Dropping the `allow_password_fallback` column now (other refs/migrations exist; a
    follow-up migration drops it).
  - Changing `password_only` mode behavior.
  - Changing SSO/JIT provisioning or gateway-proxy auth flows.

## Decisions

### Decision: Single server-side decision function `LoginPolicy.local_login_allowed?/2`

Evaluated **after** `User.authenticate` returns `{:ok, user}` (so bcrypt always runs;
uniform timing; no account-enumeration oracle). Order is significant:

1. break-glass env active → `true` (always wins; permits, still needs valid password)
2. `is_nil(user.hashed_password)` → `false` (SSO-only account, no password to accept)
3. `settings.mode == :password_only` → `true`
4. `user.local_login_enabled` → `true`
5. else → `false`

- Alternatives considered: gating inside the Ash `:authenticate` action. Rejected —
  it would couple authentication identity to web-layer auth-mode config, can't see
  the env break-glass cleanly, and the action is also used by non-web callers.

### Decision: Fail-closed on settings-resolution error

The controller resolves `AuthSettings` via `ConfigCache.get_settings/0` (not
`get_mode/0`, which returns `:password_only` on error and would silently downgrade to
"accept all"). On `{:error, _}` the controller passes `nil` settings; `LoginPolicy`
then can't match step 3 (`password_only`), so only the per-account flag or the env
break-glass can permit local login. A regular SSO user (flag `false`) with a password
is **denied** during a settings outage — exactly the SSO-enforced posture. This avoids
the "IdP/settings unreachable ⇒ fall back to password" downgrade attack.

### Decision: Break-glass is a permit, not a bypass

`SERVICERADAR_AUTH_FORCE_LOCAL_LOGIN` only makes `local_login_allowed?` return `true`
early; the bcrypt verify still had to succeed for `User.authenticate` to return
`{:ok, user}`. It needs no DB read and no IdP (read from app config seeded in
`runtime.exs`), so it recovers a deployment with broken AuthSettings. It also forces
the sign-in LiveView to render the local password form. A loud WARNING is logged at
boot when active, and each break-glass-permitted login emits an audit event. The
practical break-glass account is `root@localhost`, seeded from
`SERVICERADAR_ADMIN_PASSWORD`.

### Decision: Per-account flag defaults `false`; local actions opt-in

`local_login_enabled` defaults `false`. `:create` and `:register_with_password`
(local accounts) force it `true`; `:provision_sso_user` (JIT/SSO) leaves it `false`.
A new admin-only `:set_local_login` action (added to
`@admin_user_management_actions`, covered by the existing `@auth_manage_check`
policy) toggles it; surfaced in the admin user detail page via a new `AdminApi`
path (`:update` only accepts display fields).

## Risks / Trade-offs

- Risk: upgrade lockout. → Mitigation: UP-only backfill sets `local_login_enabled =
  true` for every account that has a password **and** where the existing
  `allow_password_fallback` was true (or unset/defaulted true), preserving exactly
  today's effective behavior. SSO-only rows (null password) stay `false`.
- Risk: operator confusion when SSO users can no longer use a password. → Mitigation:
  generic, non-enumerating flash ("This account must sign in via your organization's
  SSO"), plus the per-account toggle and break-glass env for recovery.
- Trade-off: keeping the `allow_password_fallback` column avoids a risky multi-ref
  drop now; a follow-up migration removes it.

## Migration Plan

1. Add column `local_login_enabled boolean not null default false` to
   `platform.ng_users` (Ecto migration + baseline `platform_schema.sql`).
2. UP-only backfill:
   `UPDATE platform.ng_users SET local_login_enabled = true
    WHERE hashed_password IS NOT NULL
      AND COALESCE((SELECT allow_password_fallback FROM platform.auth_settings LIMIT 1), true) = true;`
3. No down data step beyond dropping the column.
4. Follow-up (separate change): drop `allow_password_fallback` once all refs are gone.

## Open Questions

- None blocking. Disabling SSO button (`SERVICERADAR_AUTH_DISABLE_SSO`) is included as
  an optional convenience for break-glass scenarios.
</content>
