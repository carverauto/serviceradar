# Design

## D1: Named two-argument aggregates, not expressions over aggregates

`loss_ratio(sent, received)` and `wavg(value, weight)` are added as named
aggregate functions. The rejected alternative was general arithmetic over
aggregates (`sum(a*b)/sum(b)`), which would require an expression parser and
evaluator in a grammar that has none, and would make each entity's aggregate
column whitelist unenforceable — today an entity can state which columns are
aggregatable, which is how `unsupported_agg_column_is_rejected` works in
`mtr_hops.rs`.

`agg:rate_sum` is the precedent: a distinct named function rather than a
reshaped grammar, specifically so the trustworthy parts of the existing
computation stay fixed.

AST impact is additive. `StatsAggType` gains `LossRatio` and `Wavg`;
`StatsAggregation` gains a second optional field. `StatsAggType` is matched in
four parser files (`parser.rs`, `parser/ast.rs`, `parser/stats.rs`,
`parser/tests.rs`). The 36 entity modules read `StatsSpec.as_raw()` and parse it
themselves, so an entity that does not implement a new function rejects it with
`InvalidRequest` and inherits no churn.

### Null and zero-denominator semantics

A group whose denominator sums to zero yields NULL, never a division error and
never a fabricated zero. `loss_ratio` returns NULL when `SUM(sent) = 0`; `wavg`
returns NULL when `SUM(weight) = 0`. This matches `mtr_data.ex:541-556`, which
guards both with `CASE WHEN ... > 0`. A NULL group is still returned as a row so
a caller can distinguish "no probes" from "no loss"; collapsing the two is the
misreading this change exists to prevent.

`received` may be NULL in `mtr_hops`, so `wavg` coalesces the weight to zero
before summing, which makes a NULL-weight row contribute nothing rather than
voiding the group.

## D2: Time bucket as a stats group dimension

Syntax: `stats:<agg> as <alias> by <dimension>,time:<duration>`. The existing
`split_stats_group_by` already hands the whole post-`by` string to the entity,
so multi-dimension grouping needs no parser change beyond recognising the
`time:<duration>` dimension and reusing `parse_bucket_seconds`.

This is deliberately **not** `bucket:`/`downsample:`. That mechanism is a
separate single-series path (`DownsampleSpec { bucket_seconds, agg, series,
value_field }`) with its own builder, and `translate.rs` already carries an
ordering guard so a bucketed query does not fall through to it. Overloading
`bucket:` would make that dispatch ambiguous. `bucket:` is unchanged.

### Bucket expression per dialect

CNPG uses the epoch-floor form the downsample builder already emits
(`to_timestamp(floor(extract(epoch from <col>) / <secs>) * <secs>)`), which
supports arbitrary durations. TimescaleDB `time_bucket` is deliberately not used
here: it appears only in `cagg.rs` for continuous aggregates, and this path reads
raw tables.

StarRocks `date_trunc` accepts only named units, and `starrocks.rs` hardcodes
`date_trunc('hour', ...)`. Arbitrary durations therefore need either
`time_slice` or the equivalent epoch-floor arithmetic. **Open gate:** the exact
StarRocks function and its availability in the deployed version must be confirmed
before implementation; until confirmed, the StarRocks path accepts only durations
that map to a named `date_trunc` unit and refuses others with `InvalidRequest`
rather than silently rounding to the hour.

### Bucket boundary and limit interaction

Two prior defects in this area are treated as requirements, not hazards:

- `starrocks.rs:3051-3054` records a window whose `start`/`end` did not land on
  an hour boundary dropping the first and last bucket on the materialized path
  while the raw fallback kept them, so the same query resolved to a different
  cell depending on view freshness. Bucket boundaries MUST be derived
  identically on both paths.
- `downsample/sql.rs:16-25` records `sort:time:desc limit:100` returning the
  *oldest* 100 buckets, so a 30-day chart at `bucket:5m` silently stopped two
  weeks back. When `limit:` truncates a bucketed stats result, it MUST keep the
  newest buckets and still render ascending.

## D3: Backend parity is enforced, not assumed

The failure mode this change is most exposed to is the two dialect builders
drifting so the same query returns different numbers per backend — the silent
wrong answer, one layer down. Mitigations:

1. Any aggregate or dimension a backend cannot express returns
   `InvalidRequest`. Silently discarding a `stats:` clause is prohibited.
2. A shared table of (aggregate, backend) support is asserted by tests on both
   sides, so adding a variant to one builder without the other fails a test
   rather than shipping.
3. Shadow validation during MTR cutover compares CNPG and StarRocks results for
   the dashboard's own queries and reports numeric divergence, not just row
   counts.

## D4: MTR as a StarRocks dataset inside the existing framework

`add-starrocks-telemetry-analytics` owns StarRocks deployment, retention,
per-dataset cutover and the JetStream-first/EventWriter-single-owner invariant.
This change adds one dataset within that framework and redefines none of it.

MTR differs from flows deliberately: flow reads are warehouse-only and refused
before cutover, whereas MTR reads continue to serve from CNPG until its dataset
is cut over, so the dashboard keeps working throughout. No MTR data is removed
from CNPG by this change.

Per the repository rule that all telemetry flows through JetStream first, the
StarRocks MTR load path is an EventWriter consumer of an existing MTR subject,
not a new direct writer. If MTR is not currently published to JetStream, that
publication is a prerequisite task and is listed as such.

## D5: Dashboard seeding

"Seeded" is avoided here because it was actively misleading: it suggests stored
content. Nothing about the dashboard's content is stored. What ships is a
**definition** — a public `AuthoredDashboard` row plus `DashboardPanel` rows whose
`srql_query` holds SRQL text — and every panel executes that SRQL against live
data on each load.

The definition is created by the existing `SystemReports` GenServer. There is no
dashboard SDK package, no renderer artifact, no new route and no new LiveView;
`FirstPartyPackages` is the SDK-style path and is deliberately not used.

`SystemReports` is currently hardcoded for one dashboard — every function is
named `*_new_devices_*`. It becomes a list of dashboard specs, because adding a
second dashboard otherwise duplicates roughly a hundred lines.

### The reconcile must not write shipped values back

The existing reconcile is a latent bug, so it is removed rather than copied.
`maybe_update_new_devices_panel/2` calls
`maybe_put(:srql_query, panel.srql_query, @new_devices_query)`, and `maybe_put`
writes the constant back whenever the current value differs. An operator who
edits the shipped `new-devices` query therefore has it silently reverted on the
next boot — a divergence that appears long after the edit succeeded. Copying that
pattern would make this change's dashboard un-editable in the way hardest to
notice.

The replacement is **create when absent, never rewrite content**. The single
exception is a dashboard record carrying zero panels, which is an interrupted
creation rather than an operator choice, so its panels may be created. Title,
description, time range and every panel query are left alone once they exist.
The fix covers `new-devices` too, since it shares the code path.

### Authorization is already enforced, so it is verified rather than added

Changing a panel's SRQL goes through `DashboardPanel`'s
`[:create, :update, :destroy]` policy, which authorizes on the
`analytics.dashboards.edit` permission or an explicit per-dashboard grant
(`ActorCanEditDashboardChild` → `SubjectGrant.parent_dashboard_edit/1`) and fails
closed when neither matches. `AuthoredDashboard` carries the equivalent on
`[:update, :restore]`. `system_bypass()` is what lets the definition step create
the record. No new permission is introduced.

Two properties are asserted by tests rather than assumed. The built-in case —
public visibility, no owner, no grants — is the combination least covered today,
and an Ash policy does not run at all when no actor is supplied, which is the
usual way a correct policy gets bypassed. So: a view-only actor is refused a
panel query update, and the interactive edit path passes the acting user as actor.

Panel `data_binding` uses the builder's own key names (`label_field`,
`value_field`, `time_field`), so a shipped panel and a hand-built one are the same
shape and the builder can edit either.

## Resolved gates

**StarRocks bucketing — resolved.** The deployed version is StarRocks 3.5.21
(`docker-compose.yml:847`, `starrocks/allin1-ubuntu:3.5.21`), where
`time_slice(<col>, INTERVAL <n> <unit>)` is available. Arbitrary durations
therefore use `time_slice`; `date_trunc` remains for the named-unit cases
`starrocks.rs` already emits. A duration the function cannot express is refused,
never coarsened.

**MTR on JetStream — resolved, and the answer is no.**
`ServiceRadar.Observability.MtrMetricsIngestor` contains no NATS, JetStream,
subject or consumer reference; its moduledoc describes a payload received
directly from the agent, and `go/pkg/agent/mtr_checker.go:128` streams results to
the gateway. MTR therefore rides the legacy agent to gateway to core direct-write
path, the same class of exception the repository rules record for sysmon. This
change does not migrate it. The finding is handed to
`extend-starrocks-to-all-telemetry`, whose task 3.4 needs a JetStream publication
step before an MTR warehouse destination can satisfy the
JetStream-first/EventWriter-single-owner rule.

**ASN panel scope — resolved, and narrower than specified.** `mtr_hops.asn` is
populated only by `MtrMetricsIngestor.lookup_hop_asn/1` → `GeoIP.lookup/1`, which
reads GeoLite2 MMDB databases (`geoip.ex:3`). There is a fallback to an
agent-supplied value, but no agent resolves ASN — the only BGP/ASN parsing in the
repository is `rust/bmp-collector`, which feeds the separate `bmp_events` entity
and is never joined to MTR hops.

GeoLite2 maps public addresses to public ASNs. It carries no private ASNs and no
RFC1918 addresses, so `asn` is NULL for every internal hop and for every
internal-eBGP private AS. The panel therefore groups by `asn` restricted to
resolved ASNs with `asn:>0` — NULL fails the comparison — and is labelled as
external/transit rather than presented as fleet-wide. Grouping without that filter
would collapse every unresolved hop into one bucket that reads as a finding when
it is an absence of data. Ordered comparisons were added to the `asn` filter for
this; equality alone could not express it.

Real internal ASNs would have to come from the BMP feed, which needs a
cross-entity join SRQL cannot express today. That is out of scope here.
