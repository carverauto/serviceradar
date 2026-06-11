# Tasks — refactor-otel-signal-correlation

## 1. Canonical ID contract + backfill (unblocks everything else)

- [ ] 1.1 Fix the Elixir OTLP log export bridge to put raw binary ids in
      `LogRecord.trace_id`/`span_id` (root cause of double-hex `logs` ids);
      add a regression test asserting exported bytes are 16/8 raw bytes
- [ ] 1.2 Add defensive normalization in all log/trace writers (zen
      `otel_logs.rs`, Go `db-event-writer` protobuf+JSON paths, Elixir
      EventWriter processors): detect 32/16-byte ASCII-hex payloads in bytes
      fields and JSON variants (base64, uppercase) and normalize to lowercase
      hex; map all-zero/empty parent ids to NULL
- [ ] 1.3 Migration: one-time backfill decoding double-hex
      `logs.trace_id`/`span_id` (64→32 / 32→16 chars), batched, on the
      `platform` schema
- [ ] 1.4 Migration: CHECK constraints (NOT VALID → VALIDATE after backfill)
      for canonical id shape on `logs` and `otel_traces`; normalize
      `parent_span_id` `''`/`"0000000000000000"` → NULL and update root
      detection predicates to `parent_span_id IS NULL`
- [ ] 1.5 SRQL: case-fold + validate `trace_id`/`span_id` filter values;
      reject malformed/empty ids with a clear error (rust/srql parser/query
      layers; unit tests)

## 2. Trace summaries and rollups that can be trusted

- [ ] 2.1 Rework `RefreshTraceSummariesWorker` to ingest-time (`created_at`)
      watermarking with persisted watermark; remove the 5-minute event-time
      lookback; drain-until-target pruning (supersede the single-batch delete
      and reconcile with the uncommitted `TraceSummaryCleanupWorker`)
- [ ] 2.2 Unify error semantics (`status_code = 2`) across summaries,
      `traces_stats_5m`, and any UI computation; recompute or expire
      pre-conversion summary rows
- [ ] 2.3 Align retention/chunk intervals for `otel_traces`,
      `otel_trace_summaries`, `otel_metrics`, `logs` (config + migrations;
      land/extend the staged 1-hour chunk-interval migration); add a health
      check that flags tables holding data older than configured retention
- [ ] 2.4 New CAGG for span RED aggregates computed from `otel_traces` (all
      spans), replacing slow-sample-biased stats as the source for traces and
      metrics stat cards; keep `otel_metrics` slow samples as exemplars
- [ ] 2.5 OTLP metric points storage (sum/gauge/histogram with name, type,
      unit, temporality, attributes) + ingest path; rate-aware query support

## 3. Pipeline delivery accounting

- [ ] 3.1 Collector: stop ACKing failed NATS publishes (bounded buffer+retry,
      else OTLP failure response); per-signal received/published counters
      (rust/otel)
- [ ] 3.2 Consumers: per-signal received/written/rejected counters (zen, Go
      db-event-writer, Elixir EventWriter)
- [ ] 3.3 Fix docker-compose `otel.traces` vs `otel.traces.raw` subject
      mismatch; implement (or explicitly remove) the Elixir EventWriter
      protobuf trace parser TODO so no deployment shape silently drops traces
- [ ] 3.4 Root-span-ratio health signal (propagation regression detector)

## 4. Trace context propagation

- [ ] 4.1 Elixir: attach active span context to exported logs; verify
      gRPC/HTTP client propagation (web-ng → core-elx → datasvc); inject/extract
      context on internal NATS hops
- [ ] 4.2 Go: wire `InitializeTracing` into core/agent services that should
      emit spans (currently zero callers); propagate context on gRPC
- [ ] 4.3 Rust services: propagate inbound context where spans are created
- [ ] 4.4 Set span status ERROR on failures across SDK wrappers; verify error
      rate becomes non-zero-but-honest in rollups
- [ ] 4.5 Demo validation: multi-span cross-service traces visible; root-span
      ratio drops below threshold

## 5. Web-NG: trace detail + working pivots

- [ ] 5.1 New `/observability/traces/:trace_id` LiveView: span waterfall from
      `in:traces trace_id:<id>` (parent/child tree, duration bars, status
      coloring), span attribute/event inspector, "spans no longer retained"
      notice for aged-out traces
- [ ] 5.2 Traces pane rows navigate to trace detail (replace
      `correlate_trace_href` logs-tab navigation); remove clickable rows for
      summaries lacking `trace_id`
- [ ] 5.3 Correlated logs panel in trace detail (trace-scoped and span-scoped),
      time-bounded by trace start/end ± padding; logs detail `trace_id`/`span_id`
      render as links to trace detail
- [ ] 5.4 Metric sample detail: Logs/Trace buttons target trace detail and
      trace-time-bounded logs (drop hardcoded `time:last_24h`)
- [ ] 5.5 SRQL catalog: add `otel_trace_summaries` and `otel_metrics` entities;
      add `trace_id`/`span_id` to logs (and traces/metrics) `filter_fields` so
      builder round-trips preserve correlation filters
- [ ] 5.6 Fix `Stats.repo_started?` (delete the dead guard; route metrics cards
      through SRQL `rollup_stats` like the other panes); cards read the new
      full-stream RED rollups
- [ ] 5.7 Make all traces/metrics stat cards clickable with filter application
      (error cards → error-only lists); rollup staleness warnings instead of
      silent zeros
- [ ] 5.8 Fix the initial tab load dropping list results (deferred
      `{:load_tab_data, ...}` renders empty until a manual re-run on the
      metrics tab)
- [ ] 5.9 Label span samples vs OTLP metric points distinctly in the metrics
      pane; render counters as rates
- [ ] 5.10 LiveView tests: trace detail waterfall, trace→logs pivot params,
      card click filters, catalog round-trip preservation of `trace_id`

## 6. Validation in demo

- [ ] 6.1 Backfill executed on demo; `logs↔otel_traces` join-rate measured
      before/after (expect ≫0 matches after)
- [ ] 6.2 Playwright smoke: trace row → waterfall → correlated logs with
      results; metric detail → trace; cards non-zero and clickable
- [ ] 6.3 Pipeline counters: received vs written per signal within tolerance;
      retention firing (no table older than configured retention)
- [ ] 6.4 Update docs (`docs/docs/otel.md`, srql-cookbook) for canonical ids,
      trace detail, and correlation recipes; document retention defaults
