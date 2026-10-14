## Context

### Tables in scope

`ServiceRadar.Security.AuditHistory.resources/0` (the PaperTrail allow-list
behind Settings -> Audit -> History) lists 16 resources. Their version
tables, and which already have a retention worker:

| Resource | Version table | Existing worker? |
| --- | --- | --- |
| `Credentials.NetworkCredentialSecret` | `network_credential_secret_versions` | no |
| `Credentials.NetworkCredentialRule` | `network_credential_rule_versions` | no |
| `Edge.ProxmoxConsoleSession` | `proxmox_console_session_versions` | no |
| `Automation.Ansible.Controller` | `ansible_controller_versions` | no |
| `Automation.Ansible.Playbook` | `ansible_playbook_versions` | no |
| `Automation.Ansible.PlaybookRun` | `ansible_playbook_run_versions` | no |
| `Automation.Ansible.PlaybookSchedule` | `ansible_playbook_schedule_versions` | no |
| `Automation.Ansible.PlaybookRepository` | `ansible_playbook_repository_versions` | no |
| `Automation.Northbound.ActionProvider` | `northbound_action_provider_versions` | no |
| `Automation.Northbound.ActionDescriptor` | `northbound_action_descriptor_versions` | no |
| `Automation.Northbound.ActionInvocation` | `northbound_action_invocation_versions` | no |
| `Automation.Northbound.ActionEventHandler` | `northbound_action_event_handler_versions` | no |
| `Inventory.VisibilityProfile` | `visibility_profile_versions` | no |
| `Security.AuthLockout` | `auth_lockout_versions` | no |
| `Dashboards.AuthoredDashboard` | `authored_dashboard_versions` | no |
| `Dashboards.DashboardReportSchedule` | `dashboard_report_schedule_versions` | no |

`ServiceRadar.Observability.ApiEvent` (`platform.api_events`, the AshEvents
log added by `add-ash-events-audit-log`) and `ServiceRadar.Security.SecurityEvent`
(`platform.security_events`) are event logs, not version tables, and sit
outside that allow-list, but share the same "append-only, unbounded" shape.
`security_events` already has `ServiceRadar.Jobs.SecurityEventsRetentionWorker`
(90-day default), but its `retention_days` is only settable via raw Elixir
config (`config :serviceradar_core, SecurityEventsRetentionWorker,
retention_days: N`) -- there is no Helm value or env var for it, unlike every
other retention window in this codebase.

Separately, four `remote_access_*_versions` tables (`remote_access_session`,
`_request`, `_desktop_target`, `_host_key`) already have
`ServiceRadar.Edge.RemoteAccessVersionRetentionWorker`. Those resources are
**not** in `AuditHistory.resources/0` (so they don't appear in the History
view at all) but their version tables already age out. This proposal does
not touch them.

### Existing retention patterns in this codebase

Two precedents already exist for exactly this problem:

- **Single-table Oban worker**
  (`ServiceRadar.Jobs.SecurityEventsRetentionWorker`): a
  `use Oban.Worker` module, config read via `Application.get_env(:serviceradar_core,
  __MODULE__, [])`, scheduled by an Oban cron entry in
  `elixir/serviceradar_core/config/config.exs`, calling a resource-level
  delete action (`SecurityEvent.delete_older_than/2`) with a system actor.
- **Multi-table batched-delete worker**
  (`ServiceRadar.Edge.RemoteAccessVersionRetentionWorker`): one worker, one
  Oban cron entry, iterating a `@version_tables` list of
  `{table_name, retention_config_key}` pairs, each pruned with:
  ```sql
  DELETE FROM platform.<table>
  WHERE id IN (
    SELECT id FROM platform.<table>
    WHERE version_inserted_at < (now() AT TIME ZONE 'utc') - ($1::int * INTERVAL '1 day')
    ORDER BY version_inserted_at ASC
    LIMIT $2
  )
  ```
  via `Ecto.Adapters.SQL.query/4` directly (bypassing Ash), with a
  `@query_timeout_ms` and a shared `batch_size`.

Configuration for both worker shapes, and for the large
`ServiceRadar.Observability.DataRetentionWorker` (which prunes ~10 other
high-volume tables), all flow the same way:
`config/runtime.exs` reads an env var with a `parse_int_env.(NAME, default)
|> max(floor)` helper already defined in that file, and
`helm/serviceradar/templates/core.yaml` templates a Helm value into that env
var (e.g. `ANSIBLE_RETENTION_RUN_DETAIL_DAYS` from
`values.yaml`'s `ansible.runDetailDays`). This proposal's new config follows
that same three-layer wiring exactly.

### Are these tables hypertable-eligible?

Checked the actual FK shape rather than assuming: some `_versions` tables
(e.g. `remote_access_session_versions`) have a real
`version_source_id -> parent.id` foreign key with `ON DELETE CASCADE`; others
(e.g. `auth_lockout_versions`) have no FK constraint on that column at all,
just an index. Outbound FKs from a version table to its (non-hypertable)
parent are not the blocker.

The actual blocker: every one of these 18 tables has a single-column primary
key (`uuid_v7_primary_key :id` or equivalent), and Ash's code interfaces
(`get_by_id`, `Ash.get!/2`, etc.) depend on that primary key being usable
alone, without also supplying a timestamp. TimescaleDB requires the
partitioning column (here, `version_inserted_at` / `occurred_at`) to be part
of every unique constraint on a hypertable, including the primary key. Making
any of these 18 resources a hypertable would mean either dropping the
existing simple `id` uniqueness guarantee (changing each resource's identity
contract) or accepting a hypertable without a conflict-free primary key.
Native `add_compression_policy` / `add_retention_policy` are hypertable-only
features, so this is the same blocker for both.

## Goals / Non-Goals

**Goals**

- Every audit-relevant table that currently grows without bound gets a
  configurable retention window, using the two patterns already proven in
  this codebase.
- Close the one existing gap where a retention worker exists but its window
  isn't operator-configurable (`SecurityEventsRetentionWorker`).
- Keep the default behavior for `security_events` and the already-covered
  `remote_access_*` tables unchanged (same 90-day default; only the wiring
  gap closes).

**Non-Goals**

- Converting any of these 18 tables into TimescaleDB hypertables, or adding
  native Timescale compression. See the FK/primary-key analysis above --
  this is a real architectural change to each resource's identity contract,
  not a mechanical addition, and deserves its own proposal if pursued.
- A Settings UI control for retention windows. Every other retention window
  in this codebase (ansible run details, observability tables,
  `security_events`) is Helm/env-var configurable only; matching that is
  the lower-risk default. Revisit if operators specifically ask for
  runtime tuning without a redeploy.
- Changing what the History view displays or how it queries `api_events` /
  PaperTrail versions -- that's `add-ash-events-audit-log` and this
  session's separate audit-history bug-fix work, not this proposal.
- Bringing the 4 already-covered `remote_access_*_versions` tables, or
  `RemoteAccessVersionRetentionWorker` itself, into this change.

## Decisions

- **Two retention tiers, not one blanket default.** Config-audit-trail
  tables (who changed a controller, a credential, a dashboard, a lockout)
  are lower-volume and more likely to matter for a security review well
  after the fact; execution/event tables (every API event, every playbook
  run, every action invocation) are higher-volume and closer in nature to
  the existing 90-day `security_events` / `ansible.runDetailDays` defaults.
  Default windows, every one Helm/env-overridable per table:
  - **90 days** -- `api_events`, `security_events` (unchanged),
    `ansible_playbook_run_versions`, `northbound_action_invocation_versions`,
    `northbound_action_event_handler_versions`.
  - **180 days** -- the remaining 9 version tables (credential secrets and
    rules, Proxmox console sessions, Ansible controllers/playbooks/schedules/
    repositories, action providers/descriptors, visibility profiles, auth
    lockouts, authored dashboards, dashboard report schedules).
  These are starting defaults for review, not a claim that any specific
  compliance regime requires them -- an operator with a longer retention
  obligation overrides per table via Helm, same as every other retention
  knob in this chart.
- **Batched raw-SQL DELETE, not Ash destroy actions**, for the 12
  newly-covered version tables -- matching
  `RemoteAccessVersionRetentionWorker` exactly (bypassing Ash/policy
  overhead for a bulk maintenance sweep is the established pattern here,
  not a new one).
- **One new worker for the 12 version tables**, not 12 separate ones --
  same shape as `RemoteAccessVersionRetentionWorker`'s existing 4-table
  worker, just a longer `@version_tables` list.
- **One new worker for `api_events`**, following
  `SecurityEventsRetentionWorker`'s single-table shape (it already has a
  resource-level delete action pattern to mirror, and `api_events` is
  small in table count even if row volume grows).
- **Fix `SecurityEventsRetentionWorker`'s config gap in this same change.**
  Same root cause (a retention window with no Helm override), low risk
  (the fix only adds an env var read with the current hardcoded value as
  its default, so no behavior changes at deploy time unless an operator
  sets the new var).
- **No hypertable/compression, no UI** -- see Non-Goals.

## Risks / Trade-offs

- A default retention window that's wrong for a given operator's compliance
  posture would silently delete audit rows they needed. Mitigated by every
  window being overridable per table via Helm, and by defaulting to values
  that only lengthen (180 days) or match (90 days, unchanged) what's already
  the case for `security_events` today -- this change does not shorten any
  existing retention behavior.
- Splitting version-table pruning into "the `remote_access_*` worker" and
  "the new worker for the other 12" is an asymmetry a future reader has to
  learn. Mitigated by cross-referencing both workers' moduledocs.
- Raw batched `DELETE` outside of Ash bypasses per-resource policies --
  acceptable for a maintenance sweep run under a system actor context (no
  external actor triggers it), matching the existing precedent.

## Migration Plan

1. Add Helm values and `runtime.exs` env-var wiring for all new/changed
   retention windows (additive; no existing default changes).
2. Add `ServiceRadar.Observability.ApiEventsRetentionWorker` (single table)
   and its Oban cron entry.
3. Add the new 12-table version-retention worker and its Oban cron entry.
4. Wire `SecurityEventsRetentionWorker`'s `retention_days` to the new env
   var, defaulting to its current hardcoded value.
5. Verify each new worker prunes only rows older than its configured window,
   against a real database, before shipping.

## Open Questions

- Should `ActionInvocation`/`ActionEventHandler` retention track
  `ansible.runDetailDays` instead of getting their own independent knob,
  given they're conceptually the same "execution detail" class of data as
  Ansible run details? Left as two separate knobs in this proposal since
  they're different domains (Northbound actions vs. Ansible), but worth
  revisiting if operators find the number of independent retention knobs
  unwieldy.
- If an operator's compliance requirement genuinely needs longer-than-180-day
  version history at scale, hypertable conversion (accepting the primary-key
  contract change) plus native compression becomes worth its own proposal --
  intentionally deferred here rather than decided under this change's scope.
