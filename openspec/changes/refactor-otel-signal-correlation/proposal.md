# Change: Rebuild OTel trace/log/metric correlation into a usable APM experience

## Why

The OTel observability pipeline ingests millions of spans, logs, and span-derived
metrics per day into CNPG, but the product built on top of it is not usable for
debugging: clicking a trace does not show its spans, "correlated logs" links land
on an empty logs page, the metrics stat cards are hardwired to zero, and almost
every trace is a single-span trace because context propagation and correlation
were never verified end-to-end. A deep dive against the live demo database and
the current staging code found the pipeline is broken at every layer — ingestion
encoding, schema/rollups, query, and UI. The target bar is a SigNoz-class
experience: trace detail with a span waterfall, working trace↔log↔metric
pivots, and rollup-backed stats that are correct and clickable.

Verified root causes (live demo DB + code, 2026-06-11):

1. **Log trace IDs are double-hex-encoded and can never join to traces.**
   `platform.logs.trace_id` holds 64-char values like `66353863…` — the hex
   encoding of the ASCII string of the real 32-char hex trace id. Every
   consumer hexes bytes exactly once (`rust/consumers/zen/src/otel_logs.rs:155`,
   `elixir/serviceradar_core/lib/serviceradar/event_writer/processors/logs.ex:568`),
   so the OTLP `LogRecord.trace_id` bytes field already contains ASCII hex when
   the Elixir apps export logs. Decoding the stored values and joining proves
   correlation would work if the encoding were canonical (77K joins matched in a
   sample). Today `in:logs trace_id:"<hex>"` matches zero rows — the exact
   symptom users see when clicking a trace.
2. **There is no trace detail view at all.** The traces pane row click is
   `JS.navigate(correlate_trace_href(trace))` to the logs tab
   (`elixir/web-ng/lib/serviceradar_web_ng_web/live/log_live/index.ex:3674`,
   `:8474-8478`). No `/observability/traces/:trace_id` route exists, no span
   waterfall, and `parent_span_id` is never referenced anywhere in web-ng. SRQL
   fully supports `in:traces trace_id:<hex>` (indexed) but no caller ever uses
   it.
3. **Trace context propagation is broken — ~83% of spans are roots.** The demo
   DB holds ~5.0M trace summaries for ~7.0M spans (span_count=1 for nearly all),
   so "traces" are overwhelmingly single-span. Cross-process propagation
   (Elixir ↔ Go ↔ Rust services) and cross-node Erlang distribution propagation
   were never wired/verified (deferred in
   `openspec/changes/archive/2026-04-24-add-otel-elixir-instrumentation/design.md`).
4. **Metrics stat cards are structurally zero.**
   `ServiceRadarWebNGWeb.Stats.repo_started?/0` checks
   `Process.whereis(ServiceRadarWebNG.Repo)` — a delegation module that is never
   a registered process — so `metrics_summary/0` always returns the empty
   default without querying (`elixir/web-ng/lib/serviceradar_web_ng_web/stats.ex:496`,
   `:221`). Verified live: the CAGG `otel_metrics_hourly_stats` held 111K rows
   while the UI showed "0 total metrics". The same dead guard gates
   `trace_rollup_status` (`stats.ex:348`).
5. **The "metrics" pane is not metrics.** `otel_metrics` rows are per-span
   performance samples emitted only for spans slower than 100ms
   (`rust/otel/src/lib.rs:251,279`), so 96% of rows are `is_slow=true`, the
   percentiles are wildly biased (p95 ≈ 13s while real span p95 ≈ 13ms), and
   real OTLP metric points (gauges/counters/histograms) have no proper store,
   no rate/derivative rendering, and no exemplar links.
6. **Correlation links are hostile to success.** `correlate_*_href` hardcodes
   `time:last_24h` while summaries live 3 days; the logs SRQL catalog omits
   `trace_id` from `filter_fields` so a resubmit silently strips the
   correlation filter (`elixir/web-ng/lib/serviceradar_web_ng_web/srql/catalog.ex:702`);
   `otel_trace_summaries`/`otel_metrics` are missing from the catalog entirely;
   stats cards on the traces tab are not clickable; log detail shows trace/span
   ids as dead text with no reverse navigation.
7. **Rollup/maintenance fragility.** `RefreshTraceSummariesWorker` uses a
   5-minute event-time lookback (ingest lag or worker downtime silently drops
   traces forever), error semantics flip-flopped between `status_code != 1` and
   `= 2`, root detection relies on `parent_span_id = ''` while the Go protobuf
   writer emits `"0000000000000000"` for roots, retention/chunk intervals never
   fired (1-day policy vs 6h–7d chunks), and spans/logs/summaries retention is
   mutually inconsistent (1d spans vs 3d summaries vs 30d logs intent vs 7d
   actual).
8. **Silent loss by design.** The collector ACKs OTLP exports even when the
   NATS publish fails (`rust/otel/src/lib.rs:393`); the Elixir EventWriter's
   protobuf trace parser is a TODO returning nil
   (`elixir/serviceradar_core/lib/serviceradar/event_writer/processors/otel_traces.ex:138`);
   the docker-compose db-event-writer subscribes `otel.traces` while the
   collector publishes `otel.traces.raw` — traces are never written in that
   deployment.

## What Changes

- **Pin a canonical ID contract end-to-end**: trace_id = 32-char lowercase hex,
  span_id = 16-char lowercase hex, absent parent = NULL (never `''`/zeros),
  enforced at every writer, validated by CHECK constraints on new ingest paths,
  and normalized at SRQL query time (case-fold, reject non-hex). Fix the Elixir
  OTLP log export so LogRecord id fields carry raw bytes; add a one-time backfill
  that decodes existing double-hex `logs.trace_id`/`span_id` rows.
- **Fix trace context propagation** so multi-span traces exist: wire OTLP
  context propagation across Elixir↔Go↔Rust service hops (gRPC/HTTP headers,
  NATS message headers for async hops), set span status correctly, and add an
  ingest-side conformance check that alerts when root-span ratio exceeds a
  threshold.
- **Add a real trace detail experience**: new
  `/observability/traces/:trace_id` LiveView with span waterfall (built from
  `in:traces trace_id:<id>` + `parent_span_id` tree), span attributes/events
  panel, error highlighting, and tabs/panels for correlated logs (trace- and
  span-scoped) and span-derived metrics. Trace rows navigate here — never to
  the logs tab.
- **Make every correlation pivot work both ways**: logs detail links to its
  trace; metric/span samples link to trace detail and trace-scoped logs;
  correlation links derive their time window from the trace's own start/end
  (with padding), never a hardcoded `last_24h`; logs/traces/metrics SRQL catalog
  entries expose `trace_id`/`span_id` filters so builder round-trips preserve
  them.
- **Rebuild the stats cards on rollups that exist and are queried**: delete the
  broken `repo_started?` guard path, serve metrics/traces/logs cards via the
  SRQL `rollup_stats` pattern against `otel_metrics_hourly_stats`,
  `traces_stats_5m`, and `logs_severity_stats_5m`, make every card click-through
  to a filtered list, and surface rollup staleness in the UI instead of silent
  zeros.
- **Separate span performance samples from OTLP metrics**: keep `otel_metrics`
  as span samples but ingest *all* spans' RED aggregates into the hourly CAGG
  (not just >100ms outliers) so error rate/percentiles are unbiased; store real
  OTLP metric points (sum/gauge/histogram) in a dedicated metrics path with
  rate-aware rendering; label the UI accordingly.
- **Make trace summaries trustworthy**: replace the 5-minute event-time
  lookback with ingest-time (`created_at`) watermarking, unify error semantics
  on `status_code = 2`, root detection on `parent_span_id IS NULL`, align
  retention (spans, summaries, logs) and chunk intervals so retention actually
  fires, and emit operator-visible staleness warnings (adopting the unmerged
  requirement from `2026-04-24-fix-observability-query-and-trace-maintenance`).
- **Stop silent data loss**: NACK OTLP exports when the NATS publish fails (or
  buffer with bounded retry), implement protobuf trace parsing in the Elixir
  EventWriter (or formally route traces to the Go writer everywhere), fix the
  compose `otel.traces` vs `otel.traces.raw` subject mismatch, and add
  pipeline-health counters (received vs written per signal) queryable in the UI.
- **Make the collector a general OTLP backend, not a self-instrumentation
  tool** (SigNoz-parity ingest for non-ServiceRadar applications, validated
  by live conformance testing + a 5-dimension audit): OTLP/HTTP on 4318
  (protobuf+gzip+CORS), gRPC gzip/zstd acceptance with sane message limits,
  per-record `partial_success` rejection instead of poison-batch retry
  loops, OTLP-listener client-auth decoupled from platform mTLS, Helm
  LoadBalancer/Gateway exposure for the OTLP ports, ingestion-token auth,
  full-fidelity JSON attribute storage (zero/false/empty, arrays, kvlists,
  bytes — never `k=v` blobs), structured log bodies, severity_number-only
  classification, external metric points queryable with temporality-aware
  rendering, and an onboarding doc rewrite with per-language snippets and a
  repeatable conformance acceptance test (see `specs/otlp-ingest/spec.md`
  and tasks 7-9).
- **Edge OTLP ingestion as a native add-on**: package the SAME `rust/otel`
  collector crate (output side made pluggable — JetStream centrally,
  agent-forward at the edge) as a native add-on coupled with
  serviceradar-agent, so edge sites get local OTLP ingest that rides the
  existing agent→gateway mTLS channel — no new inbound ports or egress —
  with bounded store-and-forward buffering, gateway-stamped agent/site
  attribution, and downstream parity with central ingest. Also becomes the
  local telemetry endpoint for the agent, plugins, and other add-ons
  (fleet self-telemetry we currently don't collect). See design D8 and
  tasks section 10.
- **BREAKING**: `logs.trace_id`/`span_id` values are rewritten by backfill
  (double-hex → canonical hex); `otel_metrics` gains complete (non-slow-only)
  span aggregates which changes card semantics; trace row click navigates to
  trace detail instead of the logs tab.

## Impact

- Affected specs: `observability-signals` (trace detail view, correlation
  pivots, canonical ID contract, stats integrity), `srql` (id normalization,
  catalog coverage for otel entities, rollup_stats fixes), `cnpg` (schema
  constraints, retention/chunk alignment, summary maintenance, metric-point
  storage), `ash-observability` (Elixir OTLP log export correctness,
  propagation).
- Affected code:
  - `rust/otel` (collector ack/NACK, derived-metrics sampling, subjects)
  - `rust/consumers/zen`, `go/pkg/consumers/db-event-writer` (ID normalization,
    parent NULL semantics, attribute fidelity)
  - `elixir/serviceradar_core` (EventWriter processors, RefreshTraceSummaries /
    retention workers, OTLP log export bridge, migrations + backfill)
  - `rust/srql` (id normalization, spans-for-trace ergonomics, rollup filters)
  - `elixir/web-ng` (trace detail LiveView, Stats module, SRQL catalog,
    correlation links, clickable cards, log/metric detail pivots)
- Affected deployments: demo (CNPG `platform` schema backfill + retention
  fixes), docker-compose (subject mismatch fix).
- Conflicts/coordination: builds on the uncommitted retention work
  (`20260610120000_set_otel_traces_chunk_interval_one_hour`,
  `TraceSummaryCleanupWorker`) on branch `fix/bumblebee-gateway-catalog-delivery`;
  complements `add-event-writer-processor-contributions` (processor registry)
  without overlapping requirements.
