# Change: Settings → Audit → History (cross-resource AshPaperTrail timeline)

## Why

`add-platform-security-hardening` shipped a Settings → Audit
section with **Events** and **Lockouts** sub-pages, and noted
**History** as a deferred follow-up. The data exists today — every
AshPaperTrail-enabled resource writes to its own
`<table>_versions` partner table on every create/update/destroy —
but nothing surfaces it. Operators answering "who changed this
credential, and to what?" have to query the DB directly.

Concretely, the resources already on AshPaperTrail are:

- `ServiceRadar.Credentials.NetworkCredentialSecret`
- `ServiceRadar.Credentials.NetworkCredentialRule`
- `ServiceRadar.Edge.ProxmoxConsoleSession`
- `ServiceRadar.Automation.Ansible.Controller`
- `ServiceRadar.Automation.Ansible.Playbook`
- `ServiceRadar.Automation.Ansible.PlaybookRun`
- `ServiceRadar.Automation.Ansible.PlaybookSchedule`
- `ServiceRadar.Automation.Ansible.PlaybookRepository`
- `ServiceRadar.Security.AuthLockout`

Each one has a `*_versions` row per change with `version_action_type`,
`version_action_name`, `version_action_inputs`, `version_source_id`,
`changes`, and `version_inserted_at`. The actor that performed the
change is captured via `ServiceRadar.Security.Changes.StampAuditActor`,
a shared change wired into each resource's `paper_trail_mixin` that
stamps dedicated `:actor`/`:actor_id` attributes on the version row —
`version_action_inputs`/`changes[:actor]` alone are not reliable,
since some version shapes (e.g. `ActionInvocation.Version`) omit
`version_action_inputs` entirely. What's missing is a UI surface
that knits them together.

## What Changes

- **ADD** a Settings → Audit → History sub-page at
  `/settings/audit/history`, gated by `settings.audit.view`. The
  Audit tab in `SettingsComponents` already exists; we add an
  inner-nav row inside the Audit section so operators can pick
  between Events, Lockouts, and History.
- **ADD** `ServiceRadar.Security.AuditHistory` — a thin Elixir
  module that knows the list of AshPaperTrail-enabled resources
  (from a config list, see Decisions) and reads recent versions
  from each via the resource's existing AshPaperTrail
  `versions_read` action. Returns a merged, sorted-by-time stream
  keyed off `version_inserted_at`, with the parent resource module
  attached to each row so the UI can render resource-aware labels.
- **ADD** `ServiceRadarWebNGWeb.Settings.AuditLive.History` LiveView
  that paginates the merged stream, supports filters (resource
  type, actor, action type, time range), and lets the operator
  drill into a single version's full `changes` map (before/after
  rendered as a key/value diff).
- **ADD** a `config :serviceradar_core,
  ServiceRadar.Security.AuditHistory, resources: […]` allow-list
  so operators can include or exclude specific resources from the
  surface (e.g. exclude high-write-volume PlaybookRun versions
  from the default view).
- **MODIFY** the Settings → Audit nav row (currently two tabs in
  `SettingsComponents`) to include the new History tab. Existing
  Events / Lockouts tabs are untouched.

## Impact

- Affected specs: `platform-security` (ADDED requirement for the
  History surface; MODIFIED the Settings → Audit nav requirement
  to add the third tab).
- Affected code:
  - `elixir/serviceradar_core/lib/serviceradar/security/audit_history.ex`
    (new module)
  - `elixir/serviceradar_core/config/config.exs` (new
    `:resources` allow-list)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/settings/audit_live/history.ex`
    (new LiveView)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/components/settings_components.ex`
    (audit sub-tabs)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex` (new
    `/settings/audit/history` route)
  - Tests under `elixir/serviceradar_core/test/serviceradar/security/`
    and `elixir/web-ng/test/phoenix/live/settings/audit_live/`
- Operational impact:
  - Per-resource read load. The History page sweeps the configured
    resources' `*_versions` tables on every page render +
    pagination tick. Each table has its own index on
    `version_inserted_at` so per-resource reads are O(page_size).
    Filtering by resource_type pushes that down to one table.
  - No new tables, no new background jobs, no schema migration.
  - No new RBAC capabilities. Reuses `settings.audit.view` /
    `settings.audit.manage` from the merged
    `add-platform-security-hardening` change. View-only by
    default; no mutating actions on this page.
- Backwards compatibility: net additive. The Audit Events and
  Lockouts pages are unchanged.
