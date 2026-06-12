## Context

Marvin Hansen's DeepCausality example `corrective_ddos_detector` demonstrates real-time anomaly detection + corrective intervention over a continuous stream using a sliding window and a scale-invariant z-score. The ask: bring this to ServiceRadar for (a) interface-bandwidth DoS detection and (b) cross-resource capacity planning — and answer "how do we run this over a continuous stream rather than querying Postgres?"

This design is grounded in three verified inputs:

1. **The DeepCausality example** — digested from the upstream source.
2. **The live ServiceRadar stream topology** — verified against the demo cluster (`serviceradar-tools` pod, `demo` namespace, 2026-06-12) with the authenticated `nats` client.
3. **The existing `add-causal-engine` change + adjacent changes** — read in full to place this layer correctly and avoid duplication.

### Verified live NATS topology (demo, 2026-06-12)

Streams: `events` (1 GiB, `limits` retention; subjects `otel.traces.>`, `otel.metrics.>`, `logs.*`, `flows.raw.netflow`, `flows.raw.sflow`, `falco.logs`, `flow.host-slice.<agent>`, `pdns.ocsf`), `attributed_flow` (`flow.attributed.>`), `trivy_reports` (`trivy.report.>`), `ARANCINI_CAUSAL` (`arancini.updates.>`, 1.27M msgs — the causal-engine input feed).

- `otel.metrics.derived` (span RED JSON) was flowing heavily during sampling; `flows.raw.*` / `flow.attributed.>` were quiet in the demo window (flow collection not active on every agent), but the subjects/streams exist and are subscribable.
- **`telemetry.>` is on no JetStream stream** — generic SNMP/interface telemetry is not persisted to JetStream in demo (core-NATS only or inactive). Detection should not assume `telemetry.>` durability.
- The `events` stream already has ~11 durable consumers using `filter_subjects` (`db-event-writer`, `log-promotion`, per-type `serviceradar-event-writer-*`, `zen-consumer`). **A new filtered durable attaches without disturbing them** — this is the proven attach pattern.

### The load-bearing asymmetry

| Signal | On NATS? | Path |
|---|---|---|
| OTel metrics (span RED + raw) | **yes** | `otel.metrics.>` on `events` stream |
| NetFlow / sFlow | **yes** | `flows.raw.netflow|sflow` on `events` stream |
| Attributed flows | **yes** | `flow.attributed.>` on `attributed_flow` stream |
| Interface SNMP counters | sometimes | `telemetry.>` (not durable in demo) |
| **Sysmon cpu/mem/disk/process** | **NO** | agent → gateway → core **gRPC `StreamStatus`** → CNPG (`push_loop_status.go:118` → `results_router.ex:241` → `sysmon_metrics_ingestor.ex:216`) |

So **use case (a) interface bandwidth has a live stream today**; **use case (b) capacity (cpu/mem/disk) does not** — its source is gRPC-only and lands directly in CNPG. There is **no pgoutput/logical-replication CDC** (a deliberate decision in `add-causal-engine`); the rule is *never stream TimescaleDB hypertables — query them on-demand via SRQL*.

## Goals / Non-Goals

**Goals**
- Real-time, per-series statistical anomaly detection on live metric streams, with learned baselines (no per-interface manual thresholds).
- Sustained-surge confirmation that does not self-mask under a prolonged flood.
- Capacity forecasting with *time-to-exhaustion* over a multi-month horizon.
- Reuse the existing causal-engine emission spine and alert pipeline end-to-end.

**Non-Goals**
- Auto-remediation / traffic throttling in V1 (specified as a future feature-flagged phase with bounded-intervention discipline).
- Streaming hypertables / building a CDC pipeline (explicitly forbidden by the existing architecture).
- Replacing `add-interface-metric-thresholds`' static thresholds — this is the dynamic complement.
- ML/deep-learning forecasting in V1 (start with transparent statistical models).

## Decisions

### Decision 1 — Detector lives in `rust/causal-engine` (recommended), Rustler NIF as the documented alternative

**Chosen: a new `anomaly` module inside `rust/causal-engine`.** Rationale:
- DeepCausality already lives there; this is the "upgrade for the new Flow API" the platform needs (add `deep_causality_core` + `deep_causality_data_structures`).
- The engine already has a JetStream subscriber loop (`subscriber.rs`), an `emitter` that batches multiple verdict kinds, and `EmbeddedSrql` for CAGG baseline cold-start. The detector is a new module on the existing ingest seam — no new service.
- Keeps per-series window state (potentially thousands of series) out of the BEAM and off the core-elx hot path.
- Positions anomalies as first-class causal evidence (a future causaloid can consume an anomaly verdict).

**Alternative (documented, the user floated it): Rustler NIF in the core-elx `event_writer` Broadway pipeline.** The metric subjects are already consumed by Broadway processors in core-elx, so a NIF `observe(series, value, ts) -> verdict` called per datapoint would reuse that stream consumption. Trade-off: couples detection to the ingest pipeline and holds window state in the BEAM; awkward for the long-running per-sample stream model. We keep the NIF boundary clean enough that the same detector crate could be exposed either way, but V1 ships the in-engine module.

### Decision 2 — Detection algorithm: clean-baseline z-score + sustained-slot confirmation

Ported from `corrective_ddos_detector`:
- Maintain a per-series `SlidingWindow<ArrayStorage<f64, SIZE, CAP>>` (`ArrayStorage`, ~2 ns push, no_std + alloc, ~2× over-alloc; compute mean/stddev from `.slice()` — there is no built-in mean/stddev/max).
- z-score = `(sample - mean) / std`, where `std` uses **sample variance (n−1)** over the window; only computed once the window is `filled()`.
- **Withhold-anomalous-from-baseline (load-bearing):** push a sample into the baseline window **only when it is not flagged anomalous** (`if !anomalous { window.push(v) }`). This is what lets a sustained flood keep reading anomalous for its full duration; a naive "value > this window's own mean + 3σ" self-masks as the flood enters the mean.
- Confirm on **N-sigma exceedance over M consecutive slots** (defaults N = 3.0, M = 5); reset the consecutive counter on a clean tick. This is the sustained-surge gate that separates a DoS from a transient spike.
- Per-series config: `n_sigma`, `confirm_slots`, `window_size`, `min_samples`, with platform defaults; overridable per metric class (interface vs service RED).

The control loop uses the `CausalFlow` Flow DSL conceptually (`bind(analyze) -> branch_with(trigger, hot, cold)`), but real-time replaces `iterate_n(N, …)` with a **per-sample driver** invoked from the JetStream subscriber callback. The detector is **synchronous and Markovian** — each sample threads state forward; no async inside the detector.

### Decision 0 — All metrics on JetStream first (ingestion uniformity)

The asymmetry above is treated as a **defect to fix, not a constraint to design around**. The platform rule (codified in `AGENTS.md` Hard Rules and `openspec/project.md`): **every metric source publishes to NATS JetStream first and is persisted into CNPG by the `event_writer` consumer pipeline; nothing writes metrics directly to the database.** A metric that lands straight in a hypertable is invisible to real-time consumers (anomaly detection, the causal engine) until queried back out — that is the whole problem.

**Track 0 migrates sysmon** cpu/mem/disk/process off the gRPC `StreamStatus` direct-to-DB path (`push_loop_status.go:118` → `results_router.ex:241` → `sysmon_metrics_ingestor.ex:216`) onto a `telemetry.*` / `metrics.sysmon.*` JetStream subject + a new `event_writer` processor, the same shape interface/flow/OTel metrics already use. The direct CNPG write is retired; core ingests sysmon from the JetStream consumer instead. This is a prerequisite, sequenced first, behind a cutover flag (publish-and-shadow → switch the writer → remove the gRPC write).

### Decision 3 — Stream feeds (after Track 0)

- **Interface bandwidth (a):** consume `flows.raw.netflow|sflow` + `flow.attributed.>` for network throughput, and `otel.metrics.>` for service RED. SNMP interface octet rates (`telemetry.>`) are consumed when durable; otherwise interface baselining falls back to the CAGG cold-start path.
- **cpu/mem/disk/process (a + b):** with Track 0 these are **live subjects**, so the same per-sample detector covers host-resource anomalies in real time — not just capacity. Track 2 capacity forecasting still reads the hourly CAGGs via SRQL on a cron (forecasting is inherently a long-horizon batch over aggregated history, regardless of live availability); the live stream and the CAGG history are complementary, not redundant.

### Decision 4 — Baseline cold-start from CAGGs via EmbeddedSrql

A fresh `SlidingWindow` is empty, so detection is blind until it fills. On startup and on first sight of a series, seed the baseline by querying the hourly CAGG (`timeseries_metrics_hourly` / `*_metrics_hourly`) via `EmbeddedSrql` (request/response — **not** a stream) for that series' recent normal, then switch to live-stream updates. This bounds the warm-up window and survives engine restarts.

### Decision 5 — Output via the existing causal-engine spine

Emit an anomaly/forecast verdict through the existing `emitter` to `signals.causal.predictions.*` (new verdict kinds `anomaly`, `capacity_forecast`) with deterministic IDs. The existing `CausalSignals` processor + `pipeline.ex` route the `signals.causal.*` prefix into `ocsf_events`; from there `StatefulAlertEngine.evaluate_events/1` raises `device.uid`-grouped alerts and the God-View renders. **Zero new inbound plumbing.** Anomaly findings use OCSF `detection_finding` (class_uid 2004); the finding/event separation is governed by `add-ocsf-finding-model`. (The direct `events.anomaly.*` → events-batcher route also exists and reaches `ocsf_events`; we prefer the causal spine so anomalies are available to causal reasoning, but the spec permits either as the routing detail.)

### Decision 6 — Capacity forecasting is a separate batch model (NOT DeepCausality)

DeepCausality has **no forecasting primitive** (only `Uncertain<T>`/`MaybeUncertain<T>` value-uncertainty, not horizon projection). Capacity planning is therefore a distinct layer:
- An **Oban cron** job in core-elx reads the long-horizon hourly/daily CAGGs (cpu/mem/disk/process `_hourly` @395d; `flow_traffic_1h/1d` @365d; `timeseries_metrics_hourly`) via SRQL.
- Fit a transparent model first: **least-squares linear trend** for runway, plus **Holt-Winters / seasonal decomposition** where daily/weekly seasonality matters (interface traffic, cpu). Compute projected value at horizon + `projected_exhaustion_at` + a confidence/interval.
- Persist to a new `capacity_forecast` resource (Ash + raw-SQL migration per the hypertable convention) and emit a `capacity_forecast` verdict for at-risk resources so they flow into alerts and the God-View `projected_exhaustion_at` placeholder.
- **Per-interface gap:** `timeseries_metrics_hourly` has no `if_index` group key — add a per-interface hourly rollup (new CAGG or interface grouping) so link-saturation runway is computable. The capacity denominator joins live `discovered_interfaces.speed_bps` (only 3 d retention, no CAGG — utilization% is computed against current inventory, not historical capacity).

### Decision 7 — DeepCausality dependency upgrade (the "new Flow API")

Add to `rust/causal-engine/Cargo.toml`: `deep_causality_core` (monad + `CausalFlow` Flow DSL + `PropagatingProcess`/`PropagatingEffect`) and `deep_causality_data_structures` (`SlidingWindow`). Pin to versions shipping the Flow API (≈ `deep_causality_data_structures` 0.10.14, Rust edition 2024). This composes with the existing `ultragraph 0.9` pin used by the engine's graph causaloids; the BUILD/bazel deps must be updated alongside Cargo (new Rust imports break `bazel test` even when `cargo` passes).

### Decision 8 — Bounded-intervention safety (future, feature-flagged)

V1 is **detect-and-alert only**. The example's `intervene` (THROTTLE_ON) arm maps to a future guarded-remediation phase governed by the TCAS-style discipline (the "arity-5" = 5 `PropagatingProcess` channels: Value·State·Context·Error·Log): (1) trigger/score, (2) persistence/duration gate, (3) already-acting interlock, (4) clamp the action to a safe envelope, (5) audit-log every override. Any auto-action ships behind a feature flag with these five gates specified before enablement.

## Risks / Trade-offs

- **Per-series memory at scale** → bounded `ArrayStorage` windows + a per-series cap + LRU eviction of idle series; document the working-set sizing.
- **Demo metric sparsity** (flows quiet, `telemetry.>` not durable) → don't hard-depend on any one subject; CAGG cold-start makes detection useful even with thin live data; gate per-subject detection on availability.
- **Forecast false confidence** → emit confidence intervals, require a minimum history length, and label projections as estimates; never auto-remediate off a forecast.
- **Overlap with `add-interface-metric-thresholds`** → strictly complementary (dynamic vs static); do not author its `EventRule` requirements here.
- **bazel drift** → update BUILD files for new Rust deps/files (CI `bazel test` breaks even when `cargo`/`go test` pass).

## Migration Plan

1. **Track 0 first (sysmon → JetStream), behind a cutover flag:** publish sysmon to the new subject while the gRPC `StreamStatus` write still runs (shadow); switch the CNPG writer to consume from the JetStream consumer; verify parity; remove the direct write. This is reversible at each step.
2. Ship Track 1 detector behind a per-subject enable flag; validate on `otel.metrics.>` (always-live in demo) before enabling flow + sysmon subjects.
3. Add the per-interface hourly rollup migration; backfill from existing raw where available (raw is only 7 d, so forecasts ramp as CAGG history accrues).
4. Ship Track 2 forecasting cron read-only (persist + display) before wiring its verdicts into alerting.
5. Retire the bespoke netflow capacity/anomaly placeholders once the new surfaces are live.
6. Guarded auto-remediation is a separate later change; not in this one.

## Open Questions

- Should interface anomaly baselining standardize on flow-derived bps (`flows.raw.*`) or SNMP counters (`telemetry.>`) as the primary series, given `telemetry.>` is not durable in demo? (Lean: flow-derived primary, SNMP secondary.)
- Forecast model selection per resource class — is linear-trend sufficient for disk runway while interface/cpu need seasonal Holt-Winters, or do we want one configurable model? (Lean: linear default, seasonal opt-in per metric class.)
- Sysmon subject naming and stream placement: reuse `telemetry.*` (and add it as a durable subject on the `events` stream, which it is not today) vs a dedicated `metrics.sysmon.*` subject/stream? (Lean: dedicated `metrics.sysmon.*` with explicit stream config so retention/limits are tuned for high-rate host metrics.) Coordinate the agent-side aggregation with `update-sysmon-downsampling` so it lands on the publish path, not the gRPC path.
