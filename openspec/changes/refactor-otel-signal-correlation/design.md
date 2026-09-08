# Design — refactor-otel-signal-correlation

## Context

Deep dive 2026-06-11 against the live demo CNPG database (`platform` schema)
and current staging code, with multi-agent code mapping across rust/otel,
consumers (zen, Go db-event-writer, Elixir EventWriter), migrations/jobs,
rust/srql, web-ng, and the OpenSpec/docs history.

Pipeline today:

```
apps (Elixir/Go/Rust SDKs)
  → rust/otel collector (OTLP gRPC :4317, protobuf passthrough)
      → NATS JetStream stream `events`
          subjects: otel.traces.raw | otel.metrics.raw | otel.metrics.derived | logs.otel
  → consumers (zen / Go db-event-writer / Elixir EventWriter — deployment-dependent)
  → CNPG platform schema:
      otel_traces            (SPANS; one row per span; PK ts,trace_id,span_id)
      otel_metrics           (slow-span samples >100ms + some OTLP sums)
      logs                   (all log sources; trace_id/span_id TEXT)
      otel_trace_summaries   (worker-maintained per-trace rollup)
      traces_stats_5m / otel_metrics_hourly_stats / logs_severity_stats_5m (CAGGs)
  → rust/srql (embedded NIF in web-ng) → LogLive.Index tabs + detail LiveViews
```

Measured state (demo, 24h window unless noted):

| Fact | Value |
|---|---|
| spans (otel_traces) | 6.96M rows / ~6.5h retained |
| trace summaries | 5.03M (≈1.38 spans/trace; sampled span_count=1) |
| root spans (1h) | 608K roots vs 121K children (~83% roots) |
| logs with trace_id | ~1% (9K of 925K) |
| logs trace_id format | 64-char double-hex (`hex(ascii(hex(bytes)))`) — joins impossible |
| span status | 6.96M UNSET, 708 ERROR (0.01%) |
| otel_metrics is_slow | 96% true (only >100ms spans exported) |
| metrics card query (raw SQL) | 111K total — UI shows 0 |

## Goals / Non-Goals

- Goals: make trace↔span↔log↔metric correlation actually work end-to-end;
  SigNoz-class trace detail UX; honest, rollup-backed, clickable stats; no
  silent data loss; retention that fires.
- Non-Goals: APM service maps / dependency graphs; sampling strategies (head
  or tail); replacing the NATS transport; multi-tenant scoping overhaul of
  the platform schema (tracked separately by tenant control-plane work);
  alerting changes beyond rollup-staleness warnings.

## Decisions

### D1. Canonical ID contract enforced at three layers

Decision: one textual contract (32/16 lowercase hex, NULL parent for roots)
enforced at (a) producers — fix the Elixir OTLP log export to emit raw bytes;
(b) consumers — defensive normalization (detect ASCII-hex-in-bytes, base64,
uppercase; zero/empty parent → NULL); (c) database — CHECK constraints
(NOT VALID → VALIDATE post-backfill).

Why three layers: the live DB proves single-layer assumptions fail silently
(every consumer hexes exactly once, correctly — and we still got 64-char ids
because the producer put ASCII hex in a bytes field). Constraints make the
next regression loud, not invisible.

Alternatives considered: bytes (BYTEA) storage — better dedupe/size, but
rejected: every existing query/UI/SRQL/docs surface assumes text hex; the
migration risk outweighs the benefit.

Backfill: `logs` is 1-day retention in demo (≤ a few days elsewhere), so the
backfill is small and self-limiting; batched UPDATE decoding 64-char values
(`convert_from(decode(trace_id,'hex'),'utf8')`) with shape validation. Rows
older than retention age out regardless.

### D2. Root cause fixes over symptom fixes for correlation emptiness

The "click trace → empty logs" symptom has FOUR stacked causes; all are
addressed, in dependency order:

1. double-hex ids (D1) — the join can never match;
2. ~99% of logs carry no trace context — fixed by attaching active span
   context in the Elixir log export bridge and propagating context (D5);
3. hardcoded `time:last_24h` on correlation links while summaries live 3 days
   — replaced with windows derived from the trace's own start/end ± padding;
4. logs SRQL catalog omits `trace_id` from `filter_fields`, so the builder
   strips the filter on resubmit — catalog gains `trace_id`/`span_id` for
   logs/traces/metrics entities.

### D3. Trace detail is a new LiveView over existing SRQL capability

`in:traces trace_id:<hex>` already translates to an indexed single-table query
(rust/srql traces.rs) — it has simply never had a caller. The new
`/observability/traces/:trace_id` LiveView builds the waterfall client-side
from span rows (parent_span_id tree; start/end nanos for offsets). No new
query engine work beyond id normalization and default span ordering.

Considered and rejected: SQL-side recursive CTE tree assembly (unnecessary —
traces are bounded; assemble in Elixir), and building the waterfall from
`otel_trace_summaries` (insufficient — summaries have no per-span detail).

Spans aged out by retention: summaries outlive raw spans by design; the view
states "span data no longer retained" with the summary header still shown
(adopts the operator-visibility requirement stranded in the
2026-04-24-fix-observability-query-and-trace-maintenance archive).

### D4. Stats cards: delete the dead guard, standardize on rollup_stats

`Stats.repo_started?` checks `Process.whereis(ServiceRadarWebNG.Repo)` — a
defdelegate module, never a registered process — so metrics cards have been
hardwired to zero everywhere, forever (verified: `{nil, #PID<…>}` while the
CAGG held 111K rows). Rather than "fix" the process name and keep a parallel
Ecto path, metrics cards move to the same SRQL `rollup_stats` pattern the
logs/traces cards use; the guard and the direct-Ecto path are deleted.
`trace_rollup_status` (same dead guard at stats.ex:348) moves with it.

Cards become links (the logs pane already does this); traces/metrics cards
get equivalent filtered-list URLs, which requires the SRQL list entities to
accept the same predicates (error_count>0 etc.).

### D5. RED stats from the full span stream; otel_metrics demoted to exemplars

`otel_metrics` "span" rows are produced ONLY for spans >100ms
(rust/otel lib.rs:251,279) — every aggregate computed from them is biased
(96% is_slow; p95 13s vs real 13ms). Decision: a new CAGG over `otel_traces`
(time_bucket × service_name: count, error_count, duration percentiles via
percentile_agg) becomes the source for traces/metrics stat cards; slow-span
samples stay as drill-down exemplars (linked by trace_id/span_id); real OTLP
metric points get a dedicated table (name/type/unit/temporality/attributes)
with rate-aware rendering.

Alternative considered: export all spans into otel_metrics (unbiased but
doubles span write volume for data already in otel_traces) — rejected.

### D6. Summary maintenance: ingest-time watermark

The 5-minute event-time lookback drops any span arriving >5min after its
event time (worker downtime, NATS backlog, clock skew) — permanently.
Decision: persist a `created_at` watermark (high-water mark minus overlap),
upsert summaries from `WHERE created_at > $watermark`, and iterate pruning
batches under a time budget. This subsumes the single-batch cleanup and the
uncommitted drain-style `TraceSummaryCleanupWorker` (which should land/merge
here with one retention default, not two).

### D7. Delivery accounting instead of trust

The collector currently ACKs OTLP exports even when the NATS publish failed;
the Elixir EventWriter protobuf trace parser is `nil` (TODO); compose
db-event-writer subscribes a subject the collector never publishes. Decision:
per-signal received/published/written/rejected counters at collector and
consumers (Prometheus + queryable), collector returns failure (or bounded
buffer-retry) on publish failure, and the subject/parsers are reconciled so
every deployment shape has exactly one effective writer per table. A
root-span-ratio gauge provides the propagation regression alarm.

### D8. Edge OTLP ingestion: the same collector crate, packaged as a native add-on

Decision: edge OTLP ingestion reuses `rust/otel` — the exact crate behind the
central collector — packaged as a native add-on coupled with
serviceradar-agent, NOT a new collector implementation. The crate already
builds as a library (the central deployment embeds it in log-collector), and
all the conformance work in this change (gRPC gzip/limits, OTLP/HTTP 4318,
per-record `partial_success`, delivery counters, client-auth modes) lands in
that shared crate, so the edge add-on inherits it for free.

What changes to enable reuse: the crate's output side becomes pluggable. It
currently hard-couples ingestion to `NATSOutput` (JetStream publish). We
introduce an output trait with two backends: (a) the existing JetStream
backend (central deployment, unchanged), and (b) an agent-forward backend
that hands encoded OTLP batches to the local serviceradar-agent, which
relays them over its existing mTLS gateway channel; the gateway/core side
republishes onto the same NATS subjects the central collector uses, so
downstream consumers are untouched and edge data is indistinguishable from
central data. Attribution (agent id, partition/site) is stamped at the
gateway from the agent's authenticated identity — the edge needs no
ingestion tokens.

Why agent-channel transport (option A) over having the edge add-on export
OTLP directly to the central LB (option B): B is simpler but requires
outbound reachability to a second endpoint and per-site CA/token
distribution, and fails sites whose only allowed path is the gateway link —
the exact environment ServiceRadar exists for. B remains a degenerate
configuration (the output trait makes an OTLP-exporter backend cheap) for
sites that prefer it.

Buffering: the add-on buffers bounded batches on disk when the agent link is
down (oldest-first eviction, evictions counted in delivery accounting),
consistent with the platform's store-and-forward model. Add-on packaging,
signing, delivery, and config follow the completed native add-on framework
changes (delivery-models, rust SDK, edge-ops, streamed agent config); the
add-on also exposes the local endpoint that the agent, plugins, and other
add-ons use for self-telemetry.

Leaf-node transport (second first-class edge mode): where a site runs a NATS
leaf server, the collector's EXISTING JetStream backend pointed at the local
leaf becomes the preferred transport — zero new collector code, and durable
store-and-forward comes from the leaf's JetStream instead of the add-on's
own buffer (10.4 applies only to agent-channel mode). Leaf-mode specifics to
respect: (a) the leaf's JetStream runs its own domain — the edge stream is
local and reaches the hub via stream sourcing/mirroring or cross-domain
consumption, NOT by pretending to be the hub's `events` stream; (b) the
collector's current ensure_stream() force-reconciles shared stream config on
every connect (a known audit finding) — in leaf mode it must provision only
the local edge stream and never clobber hub config; (c) attribution in leaf
mode derives from the leaf connection's NATS account/creds and site-scoped
subject prefixes (ties into the existing nats-tenant-isolation and
nats-cross-account-consumption capabilities) rather than gateway stamping.
Deploying leaf servers themselves (provisioning, creds, hub-side sourcing,
retention sizing) is OUT of this change's scope — a follow-up change (e.g.
`add-nats-leaf-edge-telemetry`) owns it; this change only guarantees the
collector is transport-ready for it.

## Risks / Trade-offs

- Backfill on live demo: small (1-day logs retention) but must be batched and
  constraint-validated after; rollback = constraints stay NOT VALID.
- Propagation work spans three runtimes; risk of partial adoption →
  mitigated by the root-span-ratio signal making progress measurable, and by
  sequencing UI work to not depend on propagation (single-span traces still
  render as one-bar waterfalls with their logs).
- New RED CAGG over a high-churn hypertable with 1-hour chunks: refresh cost
  is bounded per bucket; verify on demo before enabling shorter buckets.
- Replacing metrics-card data source changes displayed numbers (intended —
  they were zeros/biased); release notes must call this out.
- Trace detail for very large traces (10k+ spans): cap rendered spans with
  server-side pagination by start time and a "showing first N" notice.

## Migration Plan

1. Land writer normalization + Elixir export fix (no schema change) — new
   data is canonical from this point.
2. Backfill migration + CHECK constraints (NOT VALID), then VALIDATE.
3. Summary worker watermark rework + retention/chunk alignment migrations.
4. New RED CAGG + metric-points table; switch Stats to rollup_stats; delete
   dead guard.
5. Ship trace detail LiveView + pivots + catalog updates.
6. Demo validation (tasks 6.x), then docs.

Rollback: each step is independently revertible; constraints can be dropped;
the old correlate links remain behind a feature flag until 5 is verified.

## Resolved Investigation Notes

- Double-hex origin (confirmed): `otel_span:hex_span_ctx/1`
  (deps/opentelemetry_api/src/otel_span.erl:114-124) intentionally produces
  hex TEXT for logger metadata (`otel_trace_id`/`otel_span_id`), and the OTLP
  logs exporter `otel_otlp_logs.erl:91-94` (opentelemetry_experimental)
  copies those metadata values verbatim into the protobuf `trace_id`/`span_id`
  BYTES fields. Consumers then hex the 32 ASCII bytes once more → 64-char ids.
  This is an upstream encoding bug in `opentelemetry_experimental`; fix via a
  patched/wrapped exporter (decode hex metadata to raw bytes before encode) in
  task 1.1, with consumer-side normalization (1.2) as the defensive layer and
  an upstream issue/PR filed.
- Demo trace writer (confirmed): the Go db-event-writer consumes
  `otel.traces.raw` protobuf and writes `otel_traces` (`processor.go:1040-1042`,
  `%x` of empty parent bytes yields `''` for roots — matching live data);
  logs flow apps → collector (`logs.otel`) → zen (`otel_logs.rs`, single hex)
  → `logs.otel.processed` JSON → Go writer verbatim. The Elixir EventWriter
  (subjects `otel.traces.>`/`logs.>`, `event_writer/config.ex:31-33`) is the
  compose-shape writer whose protobuf trace parser is the nil TODO.
- Per-tenant scoping for otel tables is deliberately out of scope here;
  the tenant control-plane workstream owns schema-level isolation.
