# Change: Add NetFlow Application Analytics (SRQL-Driven)

## Why
The current NetFlow dashboard is useful for basic traffic inspection, but it is still too shallow for rapid triage: operators need to see protocol mix, frequent talkers (by packets vs bytes), and application-level activity without leaving the page.

We also need a consistent, configurable definition of "application" for NetFlow that does not require expensive query-time lookups or ad-hoc UI heuristics.

## What Changes
- Add additional SRQL-driven NetFlow visualizations:
  - Activity by protocol (stacked area)
  - Frequent talkers tables (packet count vs byte volume)
  - Activity by application (stacked area) with a legend and drilldowns
- Introduce a NetFlow application classification system:
  - Default classification based on protocol + port mapping
  - Admin-defined overrides (rules) to refine application labels
- Extend SRQL `in:flows` to support application-level filters and group-bys (no Ecto queries for chart data).

## Impact
- Affected specs:
  - `observability-netflow`
  - `srql`
  - `cnpg`
- Affected code (expected):
  - `web-ng/` LiveView pages and JS hooks for charts
  - `rust/srql` flow query translation (application token + group-by)
  - `elixir/serviceradar_core` migrations/resources for classification rules and rollups
- Data model:
  - Adds a small rules table in `platform` for classification overrides.
  - May add a continuous aggregate (Timescale) to accelerate "activity by application" queries.

## Non-Goals
- Deep packet inspection / L7 protocol decoding.
- A full analytics "dashboard generator" (multi-panel auto-generation).
- Per-tenant or multi-deployment routing (this remains a single-deployment system).

## Progress (Updated 2026-02-08)
- Implemented SRQL-driven protocol/app stacked area charts and frequent talkers tables in `web-ng/`.
- Added `platform.netflow_app_classification_rules` (migration + Ash resource) and wired admin UI.
- Extended SRQL `in:flows` with `app` and `protocol_group` (filters + stats/downsample support) and added tests.
- Validation: `openspec validate ... --strict`, `make lint`, and `make test` are passing.
