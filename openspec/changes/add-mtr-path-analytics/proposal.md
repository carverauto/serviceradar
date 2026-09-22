# Change: MTR path analytics on statistically correct aggregates, on both backends

## Why

`in:mtr_hops` shipped with `stats:` support limited to `count/sum/avg/min/max`
over a single column. Every aggregate a path-analytics dashboard actually needs
is outside that set, so the dashboard specified by
`add-srql-mtr-hops-entity` cannot be built correctly as written.

Its `mtr-diagnostics` delta normatively requires
`stats:avg(loss_pct) by addr` and `stats:avg(loss_pct) by asn`. Averaging a
percentage is a mean of ratios, and packet loss is a ratio of sums:

```
correct:   100 * (SUM(sent) - SUM(received)) / SUM(sent)
specified: AVG(loss_pct)
```

The two differ whenever the hops in a group did not send the same number of
probes, which is always. A hop with one probe sent and one lost contributes
100% with the same weight as a hop with 500 probes and no loss. The same defect
applies to latency: `mtr_data.ex:544-545` already computes a received-weighted
mean (`SUM(avg_us * received) / SUM(received)`) because an `avg_us` derived from
one returned packet is not comparable to one derived from a hundred.

That delta's own scenario asks the ASN panel to "distinguish shared-path loss
from device-specific loss". That distinction requires a sound AS-level loss
figure; a mean of per-hop percentages does not provide one. Archiving the
change as written would replay the incorrect wording into
`openspec/specs/mtr-diagnostics/spec.md` and make it the spec of record.

This is the same class of defect as `add-srql-rate-sum`, where a panel shipped
labelled "mean rate per server and NOT a fleet total" because the correct
aggregate did not exist, and the same class as `add-srql-alerts-stats`, where a
query succeeded and answered a different question than the one asked. Shipping
an OSS dashboard whose loss column is wrong is worse than shipping no dashboard.

Separately, `stats:` has no time dimension, so no trend panel is expressible at
all. `bucket:`/`downsample:` exists but is a distinct single-series mechanism
(`DownsampleSpec { bucket_seconds, agg, series, value_field }`) that does not
compose with `stats: ... by <dimension>`.

Finally, MTR is absent from StarRocks: no schema, no consumer, and zero `mtr`
references in the 5513-line `starrocks.rs` dialect compiler. With production
moving to StarRocks, an MTR dashboard that only works against CNPG stops working
at cutover.

## What Changes

**Two SRQL aggregates, available to any entity that opts in.** Named two-argument
aggregates rather than general arithmetic over aggregates, following the
`agg:rate_sum` precedent of adding a named function instead of reshaping the
grammar:

- `loss_ratio(sent, received)` compiles to a ratio of sums, not a mean of ratios.
- `wavg(value, weight)` compiles to `SUM(value * weight) / SUM(weight)`.

`StatsAggType` gains two variants and `StatsAggregation` gains a second optional
field. Both changes are additive: `StatsAggType` is matched in four parser files
only, and the 36 entity modules consume `StatsSpec.as_raw()` and parse it
themselves, so an entity that does not implement a new aggregate rejects it
rather than inheriting churn. Zero-denominator groups return NULL, never a
division error.

**A time bucket usable as a stats group dimension**, so `:line` and `:area`
trend panels become expressible: `stats:<agg> by <dimension>,time:<duration>`.
This is distinct from `bucket:`/`downsample:` and does not change it.

**Both dialects, or an explicit refusal.** Every aggregate and the time-bucket
dimension are implemented in the CNPG builder and in `starrocks.rs`. Where a
backend cannot express a combination it MUST return `InvalidRequest`; a
`stats:` clause MUST NOT be silently dropped, and the two backends MUST NOT
return numerically different answers for the same query.

**Warehouse readiness, not a second warehouse proposal.** Moving MTR telemetry
into StarRocks is already owned by `extend-starrocks-to-all-telemetry` — its task
3.4 names "MTR traces and hops", and its requirement "All append-only telemetry
is warehouse-eligible" covers the table, the EventWriter destination, SRQL dataset
routing and warehouse rollups. Cutover parity, retention and CNPG retirement are
owned there too. This change adds no competing requirement and no duplicate
dataset work. What it does instead is make the StarRocks dialect ready: the two
aggregates and the time-bucket dimension are implemented in `starrocks.rs`, so
when MTR arrives in the warehouse the correct math already exists rather than
being added under cutover pressure, and the dashboard's panel queries are written
backend-agnostically so they survive that cutover unedited.

One finding from this change's investigation is handed to that change rather than
solved here: MTR is not published to JetStream today. `MtrMetricsIngestor`
receives a payload directly from the agent and writes CNPG, so an MTR warehouse
destination needs a JetStream publication step first to satisfy the
JetStream-first/EventWriter-single-owner rule.

**A built-in MTR path analytics dashboard**, seeded as a public authored
dashboard through the existing `SystemReports` mechanism — no dashboard SDK
package, no new route, no new LiveView. `SystemReports` is currently hardcoded
for a single dashboard and becomes a list of dashboard specs.

**The stale requirement is amended.** `add-srql-mtr-hops-entity`'s
`mtr-diagnostics` delta and its section 4 tasks are corrected so archiving it
cannot restore `avg(loss_pct)` as the required panel query.

**A latent silent-drop guard.** Six entity modules never inspect `plan.stats`
(`bmp_events`, `capacity_forecasts`, `endpoint_inventory_scans`, `field_survey`,
`source_fact_disagreements`, `virtualization`), so a `stats:` clause sent to them
is discarded and raw rows are returned. None are catalog-exposed, so no UI path
reaches them, but the API and MCP surfaces do. Each gains the explicit refusal
`mtr_traces` already uses.

## Impact

- Affected specs: `srql`, `mtr-diagnostics`.
- Affected implementation: SRQL parser AST and stats parser; `mtr_hops.rs`;
  `starrocks.rs`; the six unguarded entity modules; web-ng SRQL catalog;
  `SystemReports` dashboard seeding.
- Does not move telemetry. `extend-starrocks-to-all-telemetry` owns MTR in the
  warehouse (its task 3.4) and `add-starrocks-telemetry-analytics` owns the
  StarRocks deployment, cutover and retention framework. This change adds no
  dataset and redefines neither.
- The fail-closed and warehouse/CNPG parity requirements are owned by
  `extend-starrocks-to-all-telemetry`. This change states only the aggregate-level
  instance of them and the relational-path modules that change does not reach.
- Amends the pending `add-srql-mtr-hops-entity` rather than duplicating it. That
  change's sections 1-3 are implemented and correct and are not revisited.
- No existing aggregate changes behavior. `avg` keeps its current meaning, and a
  test asserts it still emits `AVG`.
- Phased so the CNPG dashboard can ship before the StarRocks dataset lands; see
  [tasks.md](tasks.md). Performance characteristics are acceptance criteria, not
  measured results.
