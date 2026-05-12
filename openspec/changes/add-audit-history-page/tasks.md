## 1. AuditHistory module
- [ ] 1.1 Add `ServiceRadar.Security.AuditHistory` with `list_recent/1` (filters: `:resource_types`, `:actor_id`, `:action_types`, `:since`, `:until`, `:limit`, `:offset`) returning a list of `%{resource: module, version: struct}` maps sorted by `version_inserted_at` desc.
- [ ] 1.2 Add `ServiceRadar.Security.AuditHistory.resources/0` that reads the configured allow-list from `config :serviceradar_core, ServiceRadar.Security.AuditHistory, resources: [...]` and defaults to every currently-AshPaperTrail-enabled resource.
- [ ] 1.3 Module tests: filters narrow correctly per-resource; merge ordering is stable; allow-list filter shrinks the source set; nil actor / missing email don't crash; per-resource RBAC drops unauthorized versions from the result.

## 2. Config + RBAC
- [ ] 2.1 Add the default `:resources` allow-list in `config/config.exs` to the union of currently-tracked AshPaperTrail-enabled resources: NetworkCredentialSecret, NetworkCredentialRule, ProxmoxConsoleSession, AnsibleController, AnsiblePlaybook, AnsiblePlaybookRun, AnsiblePlaybookSchedule, AnsiblePlaybookRepository, AuthLockout.
- [ ] 2.2 Confirm `settings.audit.view` is sufficient — no new RBAC permission keys.

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
