## 1. Discovery / Decisions
- [ ] Confirm the device/service identifiers to use for membership (`device_id`, `service_id`/composite keys).
- [ ] Confirm which device fields are stable for dynamic rules (partition, vendor, model, OS, tags).
- [ ] Decide the criteria format:
  - [ ] Store SRQL (recommended) vs store structured JSON rules.
  - [ ] Define a bounded evaluation window and safeguards (limit, timeout, max results).
- [ ] Decide group inheritance semantics:
  - [ ] Whether membership in a child implies membership in parents (default: yes via hierarchy, not duplicate rows).
  - [ ] Whether dynamic groups can be children of static groups.

## 2. Database (Phoenix app tables)
- [ ] Add Ecto migrations under `web-ng/priv/repo/migrations/` for:
  - [ ] `inventory_groups` (hierarchy + type device/service + system root).
  - [ ] `inventory_group_memberships` (static memberships).
  - [ ] `inventory_group_rules` (dynamic criteria + evaluation metadata).
  - [ ] `dashboards` and `dashboard_widgets` (user-owned configs).
- [ ] Add Oban tables/migrations (if not already present).
- [ ] Add indexes for scale: `(parent_id)`, `(group_type)`, `(device_id)`, `(service_id)`, `(user_id)`, etc.

## 3. Rollups (Timescale/CNPG)
- [ ] Define rollup strategy for group health:
  - [ ] Prefer shared rollups keyed by `group_id` (avoid per-group DDL).
  - [ ] Define group sysmon utilization rollups (CPU/Mem/Disk) by time bucket.
  - [ ] Define group service availability rollups by time bucket.
- [ ] Add migrations (CNPG or Phoenix, per ownership decision) to create rollups + refresh policies.
- [ ] Provide an operator runbook for rollup verification and refresh/backfill.

## 4. Background Jobs (Oban)
- [ ] Add an Oban worker to evaluate dynamic group rules and upsert memberships.
- [ ] Add an Oban worker to compute “group capabilities” (ex: sysmon present) and store in group metadata.
- [ ] Add a worker to trigger rollup refresh/backfill when a group changes.
- [ ] Add safety bounds: concurrency limits, per-run cap, and instrumentation.

## 5. UI / UX (Phoenix LiveView)
- [ ] Devices page:
  - [ ] Add group hierarchy panel (root `Inventory` → child groups).
  - [ ] Add “filter by group” and “show children” toggle.
  - [ ] Add multi-select + bulk actions (assign/remove groups).
- [ ] Group management:
  - [ ] Admin CRUD for groups and rules, with preview of dynamic membership.
  - [ ] Group detail view showing members and rollup-backed health widgets.
- [ ] Dashboard customization:
  - [ ] User dashboard editor to add/reorder widgets.
  - [ ] Add group health widgets (utilization + availability) driven by rollups with safe fallback.

## 6. Testing / Validation
- [ ] Unit tests for:
  - [ ] Group hierarchy invariants (no cycles, root can’t be deleted).
  - [ ] Dynamic rule evaluation bounds and idempotency.
  - [ ] Bulk assignment semantics.
- [ ] Smoke validation queries for rollups (raw vs rollup totals over a fixed window).

## 7. RBAC (web-ng)
- [ ] Define initial roles (ex: `admin`, `operator`, `viewer`) and the permissions needed for:
  - [ ] Group CRUD and rule evaluation controls
  - [ ] Bulk device/service edits
  - [ ] On-demand sweep scheduling and viewing results
- [ ] Add Ecto migrations for roles/assignments (or a `roles` column on `ng_users`) and any audit tables needed.
- [ ] Enforce permissions at the Phoenix router/live_session level (admin-only routes).
- [ ] Add UI affordances (hide/disable controls) but keep server-side authorization as the source of truth.
- [ ] Add basic tests for authorization boundaries (“forbidden” for non-admin).

## 8. On-demand network sweeps (admin-only)
- [ ] Decide sweep targeting model:
  - [ ] Sweep from a selected `poller_id` across its configured agents
  - [ ] Optionally target a specific `agent_id` (recommended for “sweep from this site”)
- [ ] Add Phoenix tables to track sweep runs:
  - [ ] `ondemand_sweep_runs` (who/when/params/status, retention override)
  - [ ] `ondemand_sweep_results` (summary + references to per-host results)
- [ ] Define how results are stored:
  - [ ] Reuse `sweep_host_states` with job_id correlation OR
  - [ ] Create a dedicated hypertable/table for on-demand results with 30-day retention (preferred for controlled TTL).
- [ ] Oban workers:
  - [ ] Dispatch sweep job via datasvc/KV
  - [ ] Monitor completion / timeout
  - [ ] Persist results and mark run status
- [ ] UI:
  - [ ] Admin page to schedule a sweep (select poller, input targets/options)
  - [ ] Sweep run list + detail view (status, results, export)
  - [ ] Optional embedding under a poller/agent device details page
- [ ] Retention:
  - [ ] Default 30 days, configurable per run (bounded by a max)
  - [ ] Cleanup job/policy and operator guidance
