# Tasks — refactor-otel-signal-correlation

## 1. Canonical ID contract + backfill (unblocks everything else)

- [x] 1.1 Fix the Elixir OTLP log export bridge to put raw binary ids in
      `LogRecord.trace_id`/`span_id` (root cause of double-hex `logs` ids);
      add a regression test asserting exported bytes are 16/8 raw bytes
- [x] 1.2 Add defensive normalization in all log/trace writers (zen
      `otel_logs.rs`, Go `db-event-writer` protobuf+JSON paths, Elixir
      EventWriter processors): detect 32/16-byte ASCII-hex payloads in bytes
      fields and JSON variants (base64, uppercase) and normalize to lowercase
      hex; map all-zero/empty parent ids to NULL
- [x] 1.3 Migration: one-time backfill decoding double-hex
      `logs.trace_id`/`span_id` (64→32 / 32→16 chars), batched, on the
      `platform` schema
- [x] 1.4 Migration: CHECK constraints (NOT VALID → VALIDATE after backfill)
      for canonical id shape on `logs` and `otel_traces`; normalize
      `parent_span_id` `''`/`"0000000000000000"` → NULL and update root
      detection predicates to `parent_span_id IS NULL`
- [x] 1.5 SRQL: case-fold + validate `trace_id`/`span_id` filter values;
      reject malformed/empty ids with a clear error (rust/srql parser/query
      layers; unit tests)

## 2. Trace summaries and rollups that can be trusted

- [x] 2.1 Rework `RefreshTraceSummariesWorker` to ingest-time (`created_at`)
      watermarking with persisted watermark; remove the 5-minute event-time
      lookback; drain-until-target pruning (supersede the single-batch delete
      and reconcile with the uncommitted `TraceSummaryCleanupWorker`)
- [x] 2.2 Unify error semantics (`status_code = 2`) across summaries,
      `traces_stats_5m`, and any UI computation; recompute or expire
      pre-conversion summary rows
- [x] 2.3 Align retention/chunk intervals for `otel_traces`,
      `otel_trace_summaries`, `otel_metrics`, `logs` (config + migrations;
      land/extend the staged 1-hour chunk-interval migration); add a health
      check that flags tables holding data older than configured retention
- [x] 2.4 New CAGG for span RED aggregates computed from `otel_traces` (all
      spans), replacing slow-sample-biased stats as the source for traces and
      metrics stat cards; keep `otel_metrics` slow samples as exemplars
- [x] 2.5 OTLP metric points storage (sum/gauge/histogram with name, type,
      unit, temporality, attributes) + ingest path; rate-aware query support

## 3. Pipeline delivery accounting

- [x] 3.1 Collector: stop ACKing failed NATS publishes (bounded buffer+retry,
      else OTLP failure response); per-signal received/published counters
      (rust/otel)
- [x] 3.2 Consumers: per-signal received/written/rejected counters (zen, Go
      db-event-writer, Elixir EventWriter)
- [x] 3.3 Fix docker-compose `otel.traces` vs `otel.traces.raw` subject
      mismatch; implement (or explicitly remove) the Elixir EventWriter
      protobuf trace parser TODO so no deployment shape silently drops traces
- [x] 3.4 Root-span-ratio health signal (propagation regression detector)

## 4. Trace context propagation

- [x] 4.1 Elixir: attach active span context to exported logs; verify
      gRPC/HTTP client propagation (web-ng → core-elx → datasvc); inject/extract
      context on internal NATS hops
- [x] 4.2 Go: wire `InitializeTracing` into core/agent services that should
      emit spans (currently zero callers); propagate context on gRPC
- [ ] 4.3 Rust services: propagate inbound context where spans are created
- [x] 4.4 Set span status ERROR on failures across SDK wrappers; verify error
      rate becomes non-zero-but-honest in rollups
- [ ] 4.5 Demo validation: multi-span cross-service traces visible; root-span
      ratio drops below threshold

## 5. Web-NG: trace detail + working pivots

- [x] 5.1 New `/observability/traces/:trace_id` LiveView: span waterfall from
      `in:traces trace_id:<id>` (parent/child tree, duration bars, status
      coloring), span attribute/event inspector, "spans no longer retained"
      notice for aged-out traces
- [x] 5.2 Traces pane rows navigate to trace detail (replace
      `correlate_trace_href` logs-tab navigation); remove clickable rows for
      summaries lacking `trace_id`
- [x] 5.3 Correlated logs panel in trace detail (trace-scoped and span-scoped),
      time-bounded by trace start/end ± padding; logs detail `trace_id`/`span_id`
      render as links to trace detail
- [x] 5.4 Metric sample detail: Logs/Trace buttons target trace detail and
      trace-time-bounded logs (drop hardcoded `time:last_24h`)
- [x] 5.5 SRQL catalog: add `otel_trace_summaries` and `otel_metrics` entities;
      add `trace_id`/`span_id` to logs (and traces/metrics) `filter_fields` so
      builder round-trips preserve correlation filters
- [x] 5.6 Fix `Stats.repo_started?` (delete the dead guard; route metrics cards
      through SRQL `rollup_stats` like the other panes); cards read the new
      full-stream RED rollups
- [x] 5.7 Make all traces/metrics stat cards clickable with filter application
      (error cards → error-only lists); rollup staleness warnings instead of
      silent zeros
- [x] 5.8 Fix the initial tab load dropping list results (deferred
      `{:load_tab_data, ...}` renders empty until a manual re-run on the
      metrics tab)
- [x] 5.9 Label span samples vs OTLP metric points distinctly in the metrics
      pane; render counters as rates
- [x] 5.10 LiveView tests: trace detail waterfall, trace→logs pivot params,
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

## 7. External OTLP transport conformance (SigNoz-parity ingest)

- [x] 7.1 OTLP/gRPC: accept gzip (and zstd) compressed requests; configurable
      max decoded message size (default ≥16 MiB)
- [x] 7.2 OTLP/HTTP listener on 4318: /v1/{traces,logs,metrics},
      application/x-protobuf (+gzip), CORS config; OTLP/JSON or explicit 415
- [x] 7.3 Per-record rejection: oversized/malformed records dropped + counted
      + reported via partial_success; no poison-batch retry loops; logs
      partial_success unset on full success
- [x] 7.4 OTLP listener client-auth configurable (required/optional/none)
      independent of platform mTLS
- [x] 7.5 Helm: external OTLP exposure (LoadBalancer service default-on +
      values-demo wiring; Gateway/route option documented); NetworkPolicy
      toggle for cross-namespace senders
- [x] 7.6 Ingestion token auth (header/metadata) with identity stamped on the
      NATS envelope; configurable off
- [x] 7.7 Collector publish path: remove global mutex serialization
      (clone JetStream context / bounded concurrency) to prevent
      DEADLINE_EXCEEDED storms under multi-producer load

## 8. External data fidelity

- [x] 8.1 Go writer: attributes/resource/scope/events/links as full-fidelity
      JSON (AnyValue incl. zero/false/empty, arrays, kvlists, bytes), shape
      identical to the Elixir writer
- [x] 8.2 Go writer: decode ExportMetricsServiceRequest into otel_metric_points
      (sum/gauge/histogram) and route otel.metrics.raw there; keep span
      samples separate; single owner per deployment shape (no double-ingest)
- [x] 8.3 Exponential histogram + summary points: decode or count-and-surface
      (no silent drops) in both writers
- [x] 8.4 Structured (kvlist/array) log bodies stored as JSON in the Go JSON
      path; nanosecond timestamps decoded via json.Number (no float rounding)
- [x] 8.5 Severity: severity_number fallback classification when text
      missing/unknown (incl. TRACE 1-4); never overwrite sender severity_number;
      case-insensitive severity filtering in SRQL
- [x] 8.6 Nil-resource ResourceSpans ingested (service "unknown") instead of
      dropped; rejects counted
- [x] 8.7 SRQL otel_metric_points entity + web-ng metrics pane reads points
      with temporality-aware rate/delta rendering for cumulative sums
- [x] 8.8 Schema: trace_state + dropped_{attributes,events,links}_count
      columns; scope_attributes for spans; service.namespace +
      deployment.environment promoted to first-class columns in spans +
      summaries + RED rollups
- [x] 8.9 zen: passthrough-by-default when no decision rule matches logs.otel
      (no consumed-and-ACKed silent drops); metric points series identity
      includes service.instance.id + scope; persist start_time_unix_nano for
      reset detection
- [x] 8.10 event_name filterable in SRQL + logs catalog
- [x] 8.11 Cross-writer attributes_hash parity edges: extreme-magnitude float
      rendering (1e+21 notation divergence) and >32-key nested kvlist
      ordering in the Elixir writer (Jason large-map iteration) — sort nested
      maps in Elixir + pin float formatting so Go/Elixir hashes match for all
      inputs

## 9. External onboarding

- [ ] 9.1 Rewrite docs/docs/otel.md as an onboarding page: per-deployment
      endpoint matrix, exact TLS posture, per-language env snippets,
      collector-exporter example
- [ ] 9.2 Conformance acceptance harness: telemetrygen (or equivalent)
      traces+logs+metrics against a fresh install must land end-to-end;
      wire into CI or a runbook script
- [x] 9.3 "Send your telemetry" onboarding surface: endpoint + ingestion key
      issuance + live first-data checker (phase 2)

## 10. Edge OTLP collector add-on (reuse rust/otel, ride the agent channel)

- [x] 10.1 Refactor rust/otel output side behind an output trait: JetStream
      backend (existing, central), agent-forward backend (new), optional
      OTLP-exporter backend; protocol surface (gRPC/HTTP, partial_success,
      counters, auth modes) stays shared so edge inherits all conformance work
- [x] 10.2 Agent/gateway telemetry relay: forwarding RPC (or stream reuse) on
      the agent→gateway channel carrying encoded OTLP batches; gateway/core
      republishes onto the standard NATS subjects with agent id/partition
      attribution stamped from the agent's mTLS identity
- [x] 10.3 Package the collector as a native add-on (addon-sdk, signing,
      delivery models, edge-ops lifecycle); configuration via streamed agent
      config (listen address/ports, buffer bounds, output backend)
- [x] 10.4 Bounded on-disk store-and-forward buffer with oldest-first
      eviction + eviction accounting; drain on reconnect (agent-channel
      transport only — leaf JetStream mode gets durability from the leaf)
- [ ] 10.4b Leaf JetStream transport mode: config selects local leaf URL +
      creds; leaf-safe stream provisioning (own domain/local stream only,
      never reconcile hub stream config); site-scoped subject prefixing for
      attribution; document hub-side sourcing expectations (leaf server
      deployment itself = separate change add-nats-leaf-edge-telemetry)
- [x] 10.5 Self-telemetry: agent, plugins, and co-resident add-ons export to
      the local collector when present (env/config convention, e.g. local
      OTEL_EXPORTER_OTLP_ENDPOINT); document the convention for add-on
      authors
- [x] 10.6 Attribution columns/labels surfaced in queries + UI (filter by
      agent/site); edge-vs-central indistinguishable otherwise
- [ ] 10.7 E2E: telemetrygen → edge add-on → agent → gateway → core → UI on a
      worker agent in demo; link-outage buffering test
- [x] 10.8 Spool disk-safety hardening: free-disk floor (bound-reached
      semantics under host disk pressure), shrink-bound evicts immediately
      on reconfigure, ENOSPC → evict+retry once → counted rejection; sizing
      guidance documented (defaults 256MiB; leaf transport for long-outage
      durability)
- [x] 10.9 Spool retention in the add-on settings UI (config.schema.json
      fields with titles/units/defaults) + OCSF spool-usage events via the
      SDK telemetry stream (threshold rise/clear + eviction-active,
      usage/eviction attributes) + example alert rule documented
- [ ] 10.10 Alert-rule bundle plumbing: addon/plugin manifest schema gains a
      rule-templates section; control plane seeds bundled stateful alert
      rule templates with provenance (package id+version) on import/assign;
      upgrade updates templates without clobbering customized rules;
      removal marks orphans; rule-management UI shows provenance; SDK docs
      (addon-sdk + wasm plugin SDK) define the convention
- [ ] 10.11 otel-collector add-on ships its bundle: spool utilization
      sustained-high + eviction-active templates matching the 10.9 OCSF
      event attributes (trigger + clear), documented in the add-on README
- [ ] 8.12 SRQL placeholder-rewrite sweep: the `$N`->`?` rewrite_placeholders
      idiom is copy-pasted across ~15 query modules and breaks under
      BoxedSqlQuery the moment a builder binds a parameter (endpoint_packages
      instance fixed by the DB gate; sweep the rest + the translate-path `?`
      emission for Postgrex execution)
- [ ] 8.13 srql test fixture: add otel_metric_points table (diesel defines it;
      first DB-backed test touching it will fail at fixture level)
