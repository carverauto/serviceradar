# Design: Inventory groups + customizable dashboards

## Overview
This change introduces:
- a first-class grouping model for **devices** and **services**,
- customizable dashboards that can render **group health widgets**,
- admin-only **on-demand network sweeps**, and
- **RBAC** to safely gate admin workflows.

Group health is computed from **rollups** where possible and kept up to date via **background jobs**.

## Data Model (Phoenix-owned)

### `inventory_groups`
- `id` (UUID)
- `name` (string)
- `group_type` (enum: `device` | `service`)
- `parent_id` (UUID nullable) – hierarchy
- `is_system` (boolean) – used for root `Inventory`
- `metadata` (jsonb) – capability flags (ex: `has_sysmon`, `has_snmp`)
- `inserted_at` / `updated_at`

### `inventory_group_memberships` (static)
- `group_id`
- `member_type` (`device` | `service`)
- `device_id` (nullable)
- `service_id` (nullable) – representation TBD (may be composite)
- `source` (`static` | `dynamic`)
- unique constraints per member

### `inventory_group_rules` (dynamic)
- `group_id`
- `rule_type` (`srql` | `json`)
- `query` (text) – SRQL or serialized rule definition
- `last_run_at`, `last_run_status`, `last_match_count`, `last_error`
- `enabled` (boolean)

### Dashboards
Store user-owned dashboards and widgets:
- `dashboards`: `id`, `user_id`, `name`, `is_default`, `layout_version`, timestamps
- `dashboard_widgets`: `id`, `dashboard_id`, `kind`, `title`, `config` (jsonb), `position` (jsonb), timestamps

### RBAC (initial)
Keep RBAC intentionally simple but enforce it everywhere:
- `ng_users.role` (enum: `admin` | `operator` | `viewer`) OR a join table if we need multi-role later.
- Authorization is enforced in Phoenix router/live_session boundaries; UI hiding is secondary.
- Admin-only areas include: group CRUD/rules, bulk edits, on-demand sweeps, and dashboard templates that affect shared views.

### On-demand sweeps
Track admin-triggered sweep runs and their lifecycle:
- `ondemand_sweep_runs`:
  - `id` (UUID), `requested_by_user_id`, `poller_id`, optional `agent_id`
  - `targets` (CIDR/list), `options` (jsonb), `status`, `started_at`, `finished_at`, `error`
  - `retention_days` (int, default 30, bounded)
- `ondemand_sweep_results`:
  - `run_id`, `host_ip`, `network_cidr`, `icmp_available`, open ports, metadata, timestamps
  - May reference or mirror existing `sweep_host_states` depending on final storage strategy.

## Dynamic Groups: Criteria Language
Preferred option: store SRQL queries as the rule format.
- Pros: reuses existing translator, familiar to operators, flexible.
- Safety: rules must be **bounded** (limit), have a timeout, and only target allowed entities.
- Rule evaluation runs asynchronously and materializes membership rows so the UI does not run heavy criteria queries inline.

## Group Hierarchy Semantics
- Every device/service is conceptually under the system root `Inventory`.
- Hierarchy is for presentation and filtering. Membership can be queried as:
  - `direct` members (explicit rows)
  - `effective` members (includes descendants) – computed in queries, not duplicated.
- Prevent cycles via DB constraints + application validation.

## Rollups Strategy (Timescale)
Avoid per-group DDL by creating shared rollups that are keyed by `group_id`.
- Example approach:
  - Join `inventory_group_memberships` to telemetry hypertables by `device_id`.
  - Use `time_bucket('5m', timestamp)` with `group_id` in the GROUP BY.
  - Compute summary aggregates (avg/max/p95 where applicable).

Notes:
- Timescale continuous aggregates have limitations with joins; if join-based CAGGs are not viable, fallback to:
  - materialized rollup tables updated by Oban on a schedule.

## Background Jobs (Oban)
Oban is used to keep dynamic membership and rollups current without impacting request latency.
- `GroupRuleEvalWorker`: evaluate rule → upsert memberships (source=`dynamic`).
- `GroupCapabilityWorker`: compute flags like `has_sysmon`/`has_snmp` based on recent telemetry.
- `GroupRollupRefreshWorker`: request refresh/backfill after group changes or on schedule.

### On-demand sweeps pipeline (Oban + KV/datasvc + poller/agent)
Constraints:
- `web-ng` cannot (and should not) call agents/checkers directly from request handlers.
- Pollers are the orchestrators that already talk to agents.

Proposed flow:
1. Admin schedules a sweep from `web-ng` by selecting a `poller_id` (and optionally `agent_id`) and providing targets/options.
2. `web-ng` creates an `ondemand_sweep_runs` record (`status=queued`) and enqueues an Oban job.
3. Oban worker dispatches a sweep request via datasvc/KV (NATS-backed):
   - write a job payload under a well-known key namespace scoped by `poller_id` and/or `agent_id` (ex: `jobs/sweeps/<poller_id>/<run_id>.json`).
   - include an idempotency key, TTL, and desired retention.
4. Poller watches its job namespace and, upon seeing a sweep job:
   - triggers the agent sweep service,
   - periodically calls `GetResults` until completion/timeout,
   - persists results into CNPG tables (either `ondemand_sweep_results` or correlated rows in `sweep_host_states`).
5. `web-ng` reads run status/results from the database and renders them in the UI.

Retention:
- Default to 30 days for on-demand sweep results, configurable per run but capped.
- Cleanup is enforced by Timescale retention (if hypertable) or by scheduled Oban cleanup.

## UI/UX
- Devices view adds a group tree panel and multi-select/bulk actions.
- Group pages provide CRUD, membership previews, and health widgets.
- Dashboards allow user customization and pinning group health widgets.
- Add an admin “Sweeps” area to schedule and view sweep runs/results.
