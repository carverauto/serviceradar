# Change: Portable dashboard definitions, and MTR analytics that can be scoped to a device fleet

## Why

Two problems surfaced together while trying to use the built-in MTR path
analytics dashboard to troubleshoot a fleet of endpoint devices. Neither is
fixable inside the other.

### Built-in dashboards are Elixir code

`ServiceRadarWebNG.Dashboards.SystemReports` carries the shipped dashboards as
module attributes: a list of maps with titles, SRQL strings, bindings and
layouts. That has three consequences nobody wants.

Changing a shipped dashboard requires an Elixir change, a release, and a
deployment. There is no way to **export** a dashboard an operator built in the
builder, so a dashboard that took real effort to assemble cannot be saved,
reviewed, shared between installations, or kept in version control by the
operator who owns it. And the product ships dashboards in a form no user can
produce, while asking users to build theirs a different way — the builder writes
database rows, the product writes Elixir.

There is no existing mechanism to reuse. `authored_dashboard_export_controller`
exports **panel result CSV**, not a definition. `DashboardPackage` /
`PackageImport` / `FirstPartyPackages` is the dashboard-SDK path: OCI artifacts
with compiled JS renderers, deliberately not used here. `dashboard-config.schema.json`
in `js/cli` is that same SDK format. Nothing describes an authored dashboard
declaratively, in either direction.

### MTR hop metrics cannot be scoped to a device

The dashboard's panels aggregate every hop of every trace, fleet-wide. Asked to
narrow that to one class of device, there is no way to express it:

| Table | Carries |
| --- | --- |
| `mtr_hops` | `sent`, `received`, `loss_pct`, `avg_us`, `addr`, `asn` — and only `trace_id` |
| `mtr_traces` | `device_id`, `target`, `target_ip`, `target_reached`, `total_hops`, `agent_id` |

Hop metrics and device attribution live in different tables, SRQL cannot join
entities, and `mtr_traces` **rejects** `stats:` outright — a guard added by
`add-srql-mtr-hops-entity`, whose error text advises callers to "use `in:mtr_hops`
for hop-level analytics". That advice leads nowhere: `in:mtr_hops` is exactly the
entity that cannot name a device. A source query does not bridge it either;
`panel_attrs_from_output/4` gives every panel the source's own `srql_query`, so a
source query is one query rendered several ways, not a join.

The result is a dashboard that answers "what is the fleet-wide average" when the
question is "which of these devices, or which shared hop, is broken".

## What Changes

### A portable dashboard definition format

A JSON document describes an authored dashboard and its panels: identity, default
time range, variables, and per-panel query, visual type, bindings and grid
layout. JSON rather than YAML because the payload is **already** JSON — panels
store `data_binding`, `display_config`, `visual_config`, `layout` and
`builder_state` as JSON maps — so a definition is close to a direct
serialization, round-tripping is cheap, and no new dependency is required. The
format carries an explicit version so it can evolve.

**Import** loads definitions from a declared directory and creates what is
absent. **Export** serializes an existing authored dashboard to the same format,
so a dashboard built in the builder can be saved, diffed, and imported elsewhere.
Export and import are inverses over the fields the format defines; a round-trip
test asserts it rather than assuming it.

**The shipped dashboards become data.** `new-devices` and `mtr-path-analytics`
move out of Elixir into definition files, and `SystemReports` becomes a loader
over whatever definitions ship rather than a hardcoded list. Adding or amending a
built-in dashboard stops being a code change.

**Import never overwrites operator edits.** This is a requirement, not a default.
An earlier reconcile wrote shipped values back over a differing stored query, so
an operator edit to a built-in dashboard was silently reverted on the next boot —
a divergence that only appeared after a restart. Import creates when absent and
leaves what it finds; a shipped definition changing in a later release MUST NOT
stomp a customised copy.

### MTR analytics that can name a device

`mtr_hops` gains `target_ip` and `device_id`, populated at ingest from the trace
the hops belong to, and backfilled for existing rows. `in:mtr_hops` then accepts
them as filters, so hop-level loss and latency can be scoped to a chosen set of
devices — which is what makes a fleet dashboard possible at all.

`target_ip` is the load-bearing key. On the bulk-scheduled path a trace's
`device_id` is the **command** id rather than a device uid, so `device_id` alone
would silently fail to group; the existing device-details MTR tab already matches
on `target_ip` for this reason. Both columns are added, and the dashboard uses
`target_ip`.

`mtr_traces` gains `stats:` support, replacing the blanket rejection. Trace-level
aggregation answers a question hop-level data cannot: reach rate per target,
from `target_reached` and trace counts. That is the endpoint signal — which
devices are not being reached at all — as distinct from which path segment is
lossy.

Both changes land in the relational and StarRocks compilers, per the parity rule
that a given `stats:` query returns the same semantics on either backend or is
refused.

### A dashboard that distinguishes path from endpoint

The shipped MTR dashboard is rebuilt around the diagnostic question. Aggregating
loss across all hop positions is actively misleading, because mid-path routers
deprioritize their own ICMP replies and report loss they do not cause; the
standard reading is that loss at a hop matters only if it **persists** to
subsequent hops. Panels therefore break loss down by hop position and by shared
hop address with a trace count, and pair it with per-target reach rate, so a
shared upstream fault is distinguishable from a set of individually unreachable
endpoints.

## Impact

- Affected specs: new `authored-dashboards`; `srql`; `mtr-diagnostics`.
- Affected implementation: a definition schema and loader; export; `SystemReports`
  reduced to a loader; an Elixir migration adding two `mtr_hops` columns with a
  chunk-aware backfill; `MtrMetricsIngestor`; `mtr_hops.rs`; `mtr_traces.rs`;
  `starrocks.rs`; the web-ng SRQL catalog.
- `mtr_hops` is a TimescaleDB hypertable, so the backfill is chunk-aware and
  batched rather than a single statement, and must account for compressed chunks
  where compression is enabled.
- Adding columns to a hypertable and backfilling them is the only schema change.
  All DDL goes through an Elixir migration in
  `elixir/serviceradar_core/priv/repo/migrations/` with `prefix: "platform"`.
- Does not move telemetry to StarRocks. `extend-starrocks-to-all-telemetry` owns
  MTR in the warehouse; the columns added here should be carried by its MTR table
  when that lands, and its rollups should use `loss_ratio`/`wavg`.
- Supersedes the panel set specified by `add-mtr-path-analytics`, which remains
  unarchived. That change's remaining open items (verify aggregates against real
  data, verify the dashboard renders) are answered here instead, and its task 10.1
  is withdrawn: it records that web-ng has no DB-backed Bazel target, which is
  **false** — `//elixir/web-ng:networks_live_db_test` runs against the shared SRQL
  fixture in CI and already contains authored-dashboard tests.
