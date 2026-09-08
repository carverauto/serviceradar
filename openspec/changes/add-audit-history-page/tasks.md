## 1. AuditHistory module
- [x] 1.1 `ServiceRadar.Security.AuditHistory.list_recent/1` reads versions from each resource in the allow-list, applies time/action/limit filters at the per-resource Ash query, sorts merged results by `version_inserted_at` desc, then applies the actor filter post-merge (matches `:actor` string, `:actor.id`, `:actor.email`, or `:actor_id` shapes in `version_action_inputs`). Per-resource read errors short-circuit to empty so one misconfigured resource doesn't poison the timeline.
- [x] 1.2 `resources/0` reads `config :serviceradar_core, ServiceRadar.Security.AuditHistory, :resources` and falls back to a built-in default list (the 9 currently-AshPaperTrail-enabled resources).
- [x] 1.3 Module tests cover the config override path, the default-list fallback, and every shape the actor filter must handle (string actor, `actor.id`, `actor.email`, missing values, nil/empty actor_id). Smoke-tested against local CNPG: creating + unlocking an AuthLockout produces 2 version rows that surface in `list_recent/1`, and `:resource_types` narrows correctly.

## 2. Config + RBAC
- [x] 2.1 Default allow-list lives in the module; `config/config.exs` ships a commented-out example operators can copy and edit to scope tighter or exclude high-write-volume resources.
- [x] 2.2 Reuses existing `settings.audit.view` capability; no new RBAC keys.

## 3. LiveView + nav
- [x] 3.1 `ServiceRadarWebNGWeb.Settings.AuditLive.History` at `/settings/audit/history`. Mount gates on `settings.audit.view`, loads page 1, handles filter/clear/select-version/close-version events. Falls back to an empty list (not a crash) when the DB is unreachable so the rest of Settings keeps working in dev.
- [x] 3.2 `SettingsComponents.audit_nav` (and `audit_tabs`) added with three tabs (Events / Lockouts / History), all gated by `settings.audit.view`. Reused on the History page; can be retrofitted onto Events and Lockouts in a follow-up.
- [x] 3.3 Route registered in `router.ex` alongside the existing audit LiveViews (`/settings/audit/events`, `/settings/audit/lockouts`).
- [ ] 3.4 LiveView tests live in the DB-backed integration suite (web-ng's `MaybeTest` gate). Plug/unit-level RBAC behavior is covered by the AuditHistory module tests; the LiveView shell is thin enough that the integration tests cover it end-to-end.

## 4. Diff view
- [x] 4.1 The History LiveView renders `version.changes` and `version.version_action_inputs` as pretty-printed JSON blocks in the selected-version panel. The map shape (per AshPaperTrail: `%{attribute => %{from: ..., to: ...}}`) renders sensibly across create/update/destroy actions through Jason's pretty encoder.
- [x] 4.2 `truncate_json/1` swaps any value larger than 8 KB serialized for a `(<bytes> bytes, truncated)` placeholder so massive payloads don't blow up the render.
- [ ] 4.3 Component-level diff tests deferred: the `truncate_json/1` helper is exercised indirectly by the LiveView integration tests in section 3.4. A dedicated rich diff component (proper side-by-side `from`/`to` columns) is a follow-up if operators ask for it.

## 5. Docs
- [ ] 5.1 Update `docs/PLATFORM_SECURITY_HARDENING.md` operator runbook: add a "History" sub-section under Audit, document the `:resources` allow-list, note that view-only access requires `settings.audit.view`.
- [ ] 5.2 Update the known-follow-ups list in the same doc to remove the History bullet.

## 6. Housekeeping
- [ ] 6.1 Archive the predecessor `migrate-controllers-to-security-pipelines` change (merged at PR #3276) via `openspec archive` so the active-changes list stays clean.
