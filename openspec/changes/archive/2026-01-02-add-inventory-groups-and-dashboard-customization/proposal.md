# Change: Inventory groups + dashboards + admin sweeps + RBAC

## Why
- Operators need a scalable way to organize large inventories into meaningful hierarchies (sites, environments, vendors, roles) without relying on ad-hoc SRQL filters.
- Admins need bulk workflows (select many devices/services → edit once → assign to groups) to keep the inventory curated.
- Users want dashboards that reflect *their* operational concerns (ex: “Sysmon fleet health for Site A”), not a fixed set of global cards.
- Real-time aggregate queries over hypertables are expensive; group-level health should be derived from precomputed rollups where possible.
- Operators need an admin-only, audited way to trigger **on-demand network sweeps** from a chosen poller without shell access.
- As we add powerful admin features (groups, bulk edit, sweeps), we must enforce **role-based access control (RBAC)** consistently across UI and API routes.

## What Changes
- **Groups (Devices + Services):**
  - Add hierarchical groups with a built-in root group `Inventory`.
  - Support both **static membership** (manual assignments) and **dynamic membership** (criteria-driven rules).
- **Bulk editing:**
  - Admin UI to select one/many devices (and later services) and apply changes in one place (group assignments + basic metadata/fields).
- **Dynamic groups:**
  - Admins can define criteria (partition, vendor, model, OS, tags, etc.) and the system keeps membership up to date automatically.
  - Criteria is stored declaratively and evaluated asynchronously.
- **Dashboard customization:**
  - Users can create dashboards, add/reorder/remove widgets, and save configurations.
  - Add group-scoped widgets (ex: CPU/Mem/Disk utilization summary, service availability) that can be pinned to dashboards.
- **Rollups + background jobs:**
  - Add/extend rollups to support fast group-level health queries (sysmon utilization and service availability).
  - Add background jobs (Oban) to:
    - Recompute dynamic group membership.
    - Detect “metrics availability” for a group (ex: sysmon present) and enable appropriate widgets.
    - Trigger rollup refresh/backfill when group membership or rules change.
- **On-demand network sweeps (admins only):**
  - Add an admin UI to schedule a sweep run from a selected poller (and optionally a target agent), with parameters like CIDR/targets, scan options, and retention.
  - Persist sweep run metadata and results for a bounded retention window (default 30 days; configurable).
  - Execute sweeps asynchronously via Oban, dispatching jobs through the existing NATS-backed configuration/control plane (datasvc/KV) so `web-ng` does not need direct agent connectivity.
- **RBAC:**
  - Introduce a roles/permissions model in `web-ng` and enforce it at the router/controller layer.
  - Gate group management, bulk edits, and on-demand sweeps behind admin-only permissions.

## Non-Goals
- No cut-over/migration from the legacy React UI.
- No breaking changes to ingestion semantics (core/pollers/checkers keep writing the same telemetry).
- No requirement to create one Timescale CAGG *per group* at runtime; rollups MAY be implemented as shared aggregates keyed by `group_id` (preferred).
- No fully general ABAC system. RBAC is introduced to safely support admin-only workflows; finer-grained policy can follow.
- `web-ng` MUST NOT establish direct RPC connections to agents/checkers from request handlers; all actions are asynchronous and mediated by pollers/datasvc.

## Impact
- **`web-ng/` (Phoenix):** new contexts, LiveViews, Ecto migrations (groups/dashboards/Oban), and UI changes to the Devices view for group hierarchy + bulk actions.
- **CNPG/Timescale:** new rollup objects and/or policies for group-level health queries.
- **SRQL:** MAY be used as the criteria language for dynamic groups; evaluation must remain safe and bounded.
- **KV/datasvc + pollers/agents:** add a job dispatch/watch pattern for on-demand sweeps, plus a result persistence path.
