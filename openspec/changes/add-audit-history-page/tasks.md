## 1. AuditHistory module
- [x] 1.1 `ServiceRadar.Security.AuditHistory.list_recent/1` reads versions from each resource in the allow-list, applies time/action/limit filters at the per-resource Ash query, sorts merged results by `version_inserted_at` desc, then applies the actor filter post-merge (matches `:actor` string, `:actor.id`, `:actor.email`, or `:actor_id` shapes in `version_action_inputs`). Per-resource read errors short-circuit to empty so one misconfigured resource doesn't poison the timeline.
- [x] 1.2 `resources/0` reads `config :serviceradar_core, ServiceRadar.Security.AuditHistory, :resources` and falls back to a built-in default list (the 9 currently-AshPaperTrail-enabled resources).
- [x] 1.3 Module tests cover the config override path, the default-list fallback, and every shape the actor filter must handle (string actor, `actor.id`, `actor.email`, missing values, nil/empty actor_id). Smoke-tested against local CNPG: creating + unlocking an AuthLockout produces 2 version rows that surface in `list_recent/1`, and `:resource_types` narrows correctly.

## 2. Config + RBAC
- [x] 2.1 Default allow-list lives in the module; `config/config.exs` ships a commented-out example operators can copy and edit to scope tighter or exclude high-write-volume resources.
- [x] 2.2 Reuses existing `settings.audit.view` capability; no new RBAC keys.

## 3. LiveView + nav
- [ ] 3.1 Add `ServiceRadarWebNGWeb.Settings.AuditLive.History` LiveView at `/settings/audit/history`. `on_mount` gates on `settings.audit.view`. Mount loads page 1 with default filters; `handle_event("filter", _, _)` re-runs the query.
- [ ] 3.2 Add inner-nav (Events / Lockouts / History) on the Settings → Audit sub-pages so operators can pivot. Implemented as a small `<.audit_subnav current_path={...} />` component in `SettingsComponents`.
- [ ] 3.3 Add the route in `router.ex` under the existing audit live-view block, piped through `:browser` like the others.
- [ ] 3.4 LiveView tests: page renders for `settings.audit.view`; filter form round-trips state; the resource-type selector lists the configured allow-list; unauthorized actor (no `settings.audit.view`) is redirected.

## 4. Diff view
- [ ] 4.1 Add `audit_changes_diff/1` function component that renders the `changes` map as a two-column key/value table. Handles create (`from: nil`), destroy (full snapshot), and update (before/after) shapes.
- [ ] 4.2 Large jsonb values (> 8 KB serialized) show a "truncated" badge with byte size and an expand control.
- [ ] 4.3 Component tests: each action_type renders the expected shape; truncation badge appears at the byte threshold.

## 5. Docs
- [ ] 5.1 Update `docs/PLATFORM_SECURITY_HARDENING.md` operator runbook: add a "History" sub-section under Audit, document the `:resources` allow-list, note that view-only access requires `settings.audit.view`.
- [ ] 5.2 Update the known-follow-ups list in the same doc to remove the History bullet.

## 6. Housekeeping
- [ ] 6.1 Archive the predecessor `migrate-controllers-to-security-pipelines` change (merged at PR #3276) via `openspec archive` so the active-changes list stays clean.
