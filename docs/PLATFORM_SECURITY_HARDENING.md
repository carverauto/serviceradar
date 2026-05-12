# Platform Security Hardening — Operator Notes

This document covers the operator-facing surface added by the
`add-platform-security-hardening` OpenSpec change. The bulk of the
change is invisible (plugs that enforce rate limits, sanitize
uploads, hardened response headers, etc.). What follows is the part
operators need to know to roll it out, monitor it, and tune it.

## 1. Rollout order

Land + observe in this order. Each step is independently revertible.

1. **Section 1–2: shared rate limiter + plug + auth shim.** Behavior-
   neutral — the existing `Auth.RateLimiter` now delegates to the new
   cluster-aware `ServiceRadar.Security.RateLimiter` with the same
   per-call opts. Watch for the
   `[:serviceradar, :security, :events, :dropped]` telemetry counter
   to confirm the event recorder is happy.
2. **Section 3: security headers in CSP report-only mode.** Already
   the default in `config/config.exs`. After at least 7 days of
   `/api/security/csp-report` reception, audit
   `Settings → Audit → Events` filtered to `kind = csp_violation` and
   resolve any genuine violations.
3. **Section 4 + 6: upload guard + event stream.** Plug exists;
   wiring onto specific routes happens during the per-controller
   migration (below). Section 5 (webhook signature plug) was dropped
   from scope — serviceradar has no inbound HTTP webhook routes;
   Falco / datasource events flow over NATS.
4. **Section 7–8: lockout machinery + RBAC capabilities.** Lockout
   triggers only fire when controllers call
   `ServiceRadar.Security.Lockouts.record_failed_login/2`, so the
   feature is dormant until the controller migration step.
5. **Section 9: Settings → Audit UI.** Visible immediately to anyone
   with `settings.audit.view`.
6. **Section 10: session cookie hardening.** **One-time forced
   sign-out at the deploy.** Communicate ahead of time.
7. **Section 11 (this step): controller migration.** Per controller,
   in this order:
   - Move the inline `Auth.RateLimiter.check_rate_limit_and_record`
     call to the appropriate `:rate_limit_*` pipeline in `router.ex`,
     remove the inline call. Different bucket key → no double-count
     during the transition.
   - Add a `record_failed_login/2` call after credential mismatch.
   - For binary upload routes: pipe the `UploadGuard` plug, drop the
     inline content-type/size checks.
8. **Flip CSP to enforce.** `config :serviceradar_web_ng,
   ServiceRadarWebNGWeb.Plugs.SecurityHeaders, csp_mode: :enforce`
   once report-only has been clean for ≥ 7 days. Keep the report URI
   in place — enforced CSP still emits reports for the bits the
   browser blocked.

## 2. Required env vars (release builds)

`config/prod.exs` reads these at `mix release` time. Builds will
**fail** if either salt is missing.

| Variable                  | Required | Default     | Notes |
|---------------------------|----------|-------------|-------|
| `SESSION_SIGNING_SALT`    | yes      | —           | 16+ random bytes; rotating invalidates sessions. |
| `SESSION_ENCRYPTION_SALT` | yes      | —           | 16+ random bytes; rotating invalidates sessions. |
| `SESSION_COOKIE_SECURE`   | no       | `true`      | Set to `false` only for staging served over HTTP. |

Generate fresh values with `mix phx.gen.secret 32 | head -c 24`.

## 3. Tuning rate limit buckets

Buckets live in `config :serviceradar_core, ServiceRadar.Security.RateLimiter`.
Each entry is `[limit: N, window_seconds: S]` (sliding window).
Override per environment as needed:

```elixir
# config/runtime.exs or per-env config
config :serviceradar_core, ServiceRadar.Security.RateLimiter,
  buckets: %{
    cli_device_auth: [limit: 60, window_seconds: 60]
  }
```

`config.exs` ships sensible defaults for all named buckets.

## 4. Unlocking an account

1. `Settings → Audit → Lockouts`.
2. Confirm the actor in the table (a lockout row also lists the
   trigger reason and expiration).
3. Click **Unlock**. Requires `settings.audit.manage`.
4. A `:lockout_cleared` SecurityEvent records the admin who cleared
   it. The lockout row stays in the table with `cleared_at` /
   `cleared_by` populated for audit history.

Automatic expiration: lockouts default to a 1h `expires_at`. If you
want a tenant-wide permanent lockout, drop a row directly via
`ServiceRadar.Security.AuthLockout.lock_actor/2` with
`expires_at: nil`.

## 5. CSP escape hatch

If a specific route serves third-party content that violates CSP:

- Short-term: flip CSP back to `:report_only` via runtime config
  without redeploying.
- Per-route: add a custom pipeline that excludes
  `ServiceRadarWebNGWeb.Plugs.SecurityHeaders` for the affected route.
- Long-term: extend `@csp` in `router.ex` with the specific
  directive (`script-src 'self' https://trusted.example`).

## 6. Known follow-ups

- **AshPaperTrail unified history page.** The Audit UI lists the
  event stream and current state of lockouts but does not yet
  surface cross-resource version history. Each resource already
  writes to its own `*_versions` table; the cross-cutting
  query + diff view is tracked separately.
- **Cluster-aggregated rate-limit inspection.** The
  `Settings → Audit → Rate Limits` panel is not built yet — bucket
  state lives in per-node ETS and needs an aggregated read path.
- **Per-IP progressive backoff inside the limiter.** Cross-IP account
  lockout (section 7.4) is in place; the `[1m, 5m, 30m, 24h]`
  escalation inside the sliding-window math is a separate change.
- **`mix ash.codegen` workflow rework.** The migration file
  (`20260512040000_add_security_resources.exs`) was hand-written
  with `use Ecto.Migration` to match every other migration in
  `priv/repo/migrations/`. The Ash codegen workflow described in
  `elixir/serviceradar_core/CLAUDE.md` is currently unusable
  because `priv/resource_snapshots/` was gitignored in the January
  cleanup PR — settling that convention is tracked in Forgejo
  issue #3269.
