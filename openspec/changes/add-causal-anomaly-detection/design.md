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
- **Seasonal-aware detection** — answer "is this abnormal for a Tuesday 9am?" via per-series day-of-week × hour-of-day profiles, consulted in real time.
- Capacity forecasting with *time-to-exhaustion* over a multi-month horizon.
- **Horizontally scalable, stateful consumers** — partitioned by series key, autoscaled on queue pressure (KEDA).
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

**Track 0 covers every metric source not already durably on JetStream**, onto a **dedicated `metrics` stream** (subjects `metrics.>`; `limits` retention — see Decision 9):
- **Sysmon** cpu/mem/disk/process — migrate off the gRPC `StreamStatus` direct-to-DB path (`push_loop_status.go:118` → `results_router.ex:241` → `sysmon_metrics_ingestor.ex:216`) onto `metrics.sysmon.*` + a new `event_writer` processor; retire the direct CNPG write; core ingests from the JetStream consumer instead.
- **SNMP interface telemetry** — verified **not durable on JetStream today** (`telemetry.>` is on no stream; a live `nats sub` returned nothing). Route SNMP interface counters (ifHCInOctets/ifHCOutOctets with `if_index`) onto `metrics.snmp.*` so interface anomaly detection has a reliable live feed and the data is durably persisted by the DB-sync consumer.

Each is sequenced behind a cutover flag (publish-and-shadow → switch the writer → remove any legacy path). Flow/OTel metrics already on the `events`/`attributed_flow` streams may migrate onto the dedicated `metrics` stream over time for consistency, but that migration is not required by this change.

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

### Decision 9 — Dedicated metrics stream + consumer fan-out (the ack model)

**A dedicated `metrics` JetStream stream** (subjects `metrics.>`, e.g. `metrics.sysmon.*`, `metrics.snmp.*`, with flow/otel metrics migrating onto it over time) is the target for Track 0. It **MUST use `limits` (or `interest`) retention — never `workqueue`.** This is load-bearing: JetStream consumers are independent fan-out views, each with its own cursor, and under `limits` retention **an ack only advances that consumer's position; it does not delete the message.** So multiple durable consumers each receive every message.

Verified live on the existing `events` stream (`retention: limits`, `discard: old`, `max_age: 1800s`): `db-event-writer` (durable, `ack_policy: explicit`, `deliver_policy: all`, `max_deliver: -1`) **and** `serviceradar-event-writer-otel-metrics` (durable, explicit ack) **both consume `otel.metrics.>` independently today.** The anomaly detector is simply a third independent consumer — its ack has zero effect on the DB-sync consumer, which keeps its own cursor and syncs to CNPG regardless. A `workqueue` stream (delete-on-first-ack) would break this and is forbidden for metrics.

Two consumer profiles, by job:

| | DB-sync consumer (persist to CNPG) | Anomaly detector consumer |
|---|---|---|
| Durable | yes | optional (ephemeral, or durable + short `inactive_threshold`) |
| `deliver_policy` | `all` (catch up; no data loss) | **`new`** (live only; never replay a backlog) |
| `ack_policy` | explicit, `max_deliver: -1` (at-least-once) | explicit or none — own cursor only |
| Durability needed | yes — must not lose DB data | no — dropping samples during downtime is acceptable; reseeds from CAGGs |

The stream's short `max_age` means the detector cannot replay a long backlog even in principle, which is why `deliver_policy: new` + CAGG cold-start is the only sane restart model (Decision 10).

### Decision 10 — Restart survival

The detector's per-series windows are in-memory, so a restart must be handled explicitly:
1. **Durable/ephemeral consumer with `deliver_policy: new`** — on reconnect it resumes live and does not replay a backlog (which the 30-min stream age forbids anyway).
2. **Compact per-series state snapshot** persisted to a durable store (a small CNPG table or a JetStream KV bucket) on a timer + graceful shutdown: the last N window samples + running counters (consecutive-anomaly count, last-fired timestamp). On boot, restore it — exact and small (N floats per series; the window is bounded).
3. **Cold-start fallback** for series with no snapshot (first boot, new interface): seed baseline statistics from the hourly CAGG via EmbeddedSrql and **suppress findings until the window re-warms** (the min-samples guard). A brief post-restart detection gap is acceptable and documented.
4. **Track 2 capacity forecasting is stateless across restarts** — it recomputes from CAGGs each run, so it has no restart concern at all.

### Decision 11 — Baseline time constants: three tiers, not one

The rolling window is deliberately **short and recent** — it is the wrong tool for slow trends or seasonality, and that is by design, not a gap:

- **Tier A — streaming spike detection (Track 1):** bounded rolling window, **minutes to tens of minutes**, in-memory. `baseline_duration = window_size × sample_interval`; at sysmon's 10–60 s cadence, ~30 samples = 5–30 min. Enforce a **min-samples floor (~20–30)** so the mean/variance are statistically stable (too short → noisy baseline → inflated threshold → missed spikes). This catches *sudden* surges (DoS, runaway process) well. The "baseline exceeded for X period" is a **separate knob** — the M-consecutive-slot confirmation (`M × interval`) — not the baseline length.
- **Tier B — capacity forecasting (Track 2):** weeks–months from the CAGGs, batch. Catches *slow ramps* toward exhaustion that any short-window detector misses (boiling-frog).
- **Tier C — seasonal-baseline anomaly (IN SCOPE — see Decision 13):** "abnormal vs the same hour last week." A short rolling z-score cannot do this (a normal Monday-9am ramp false-positives against a 5-min window). The seasonal profile is the right structure and is consulted by the streaming detector per-sample, not just a delayed batch pass.

**Is the rolling window long enough for cpu/mem/disk/interface spikes?** For sudden spikes, yes — when window length is configurable per metric class and respects the min-samples floor. It is intentionally not long enough for slow trends (→ Tier B) or seasonal context (→ Tier C). The detector combines all three signals.

### Decision 13 — Seasonal-baseline detection (first-class)

"Is this abnormal for a Tuesday 9am?" requires modeling periodic seasonality, which the rolling window cannot. Approach:

- **Seasonal profile per series, keyed by (day-of-week × hour-of-day)** — 168 buckets. Each bucket holds a **robust** center and spread (**median + MAD**, not mean/σ, so a past incident in the history does not poison the profile). Profiles are computed from the **hourly CAGGs** over the last K weeks (395-day CAGG retention ≈ 56 weeks — ample for stable weekly seasonality).
- **Computed in batch** (refreshed ~daily), persisted to CNPG, and **consulted by the streaming detector per-sample as a second baseline.** A live sample is scored against both the short rolling window (sudden) and the seasonal bucket (off-pattern), so seasonal awareness is real-time, not a delayed batch verdict. The same profile also supports a standalone batch seasonal evaluation.
- **Three combined signals:** rolling-window z-score (sudden) · seasonal-profile deviation (off-pattern) · trend/forecast (slow exhaustion, Track 2). The detector fires on a configurable combination per metric class.
- **Reliability guardrails:** require a minimum weeks-of-history before a bucket is trusted (fall back to the rolling window until then); use robust statistics; expose the seasonal sensitivity as a config knob (Decision 12). **Upgrade path:** STL decomposition / Holt-Winters (seasonal+trend+residual, ESD on residuals) — which also unifies with the Track 2 forecaster. **Known limitation (documented, not solved in V1):** holidays / irregular non-weekly events.

### Decision 14 — Horizontal scalability: partitioned consumers, queue groups, KEDA

The detector is **stateful per series** (each series owns a sliding window), which dictates how it scales:

- **Stateful detector → partitioned consumers, NOT plain queue groups.** A NATS queue group round-robins messages with no affinity, which shreds a per-series window across instances. Instead **partition the metrics stream by series key** (a partition token in the subject, `hash(series_key) % N`); each detector replica owns a partition (and therefore a deterministic set of series + their windows). This is parallelism *with* affinity. **Partition count is the scaling ceiling and is hard to change later — size it generously up front.**
- **Stateless DB-sync → queue group / shared pull consumer is fine** — no per-series state, so work-sharing across replicas is correct.
- **KEDA autoscaling on JetStream lag:** scale replicas on consumer `num_pending` (pending messages) via the KEDA NATS JetStream scaler. KEDA is already installed and in use in the cluster (keda-operator, ScaledObjects with metrics-api triggers). Make KEDA a documented **install requirement** for ServiceRadar k8s deployments, with a static-replica fallback for non-KEDA installs.
- **Broadway nuance:** Broadway is not a standalone pod — it is a GenStage topology inside the BEAM with its own internal concurrency and demand backpressure. So the layers are distinct: **KEDA scales the number of pods** (the standalone `rust/causal-engine` detector, or core-elx replica count); **Broadway's processor/batcher concurrency scales within a pod** via config, and KEDA must not try to drive it. KEDA is the right tool for the standalone Rust detector and for core-elx replica count; it is the wrong tool for tuning Broadway's internal stages. When scaling core-elx (Broadway DB-sync) by replicas, each replica shares the same pull consumer (queue-group semantics), and KEDA drives the replica count on lag.

### Decision 12 — Configuration lives in CNPG + settings UI, seeded from Helm

All detector and forecast tuning knobs are operator-facing and MUST be editable without a redeploy: N-sigma threshold, window size/duration, confirm-slots (the "for X period"), min-samples, per-metric-class overrides (interface / RED / cpu / mem / disk), forecast horizon, warning threshold, and model choice (linear / seasonal). These are stored in **CNPG (an Ash resource)**, **seeded from Helm chart defaults on first boot**, and edited in the **settings UI**. The engine reads config from CNPG with periodic refresh / hot-reload, so changes take effect without restarting the detector. This follows the existing observability-rule-management / settings pattern; stream and consumer config (retention, subjects) remain Helm/infra-managed.

## Risks / Trade-offs

- **Per-series memory at scale** → bounded `ArrayStorage` windows + a per-series cap + LRU eviction of idle series; document the working-set sizing.
- **Demo metric sparsity** (flows quiet, `telemetry.>` not durable) → don't hard-depend on any one subject; CAGG cold-start makes detection useful even with thin live data; gate per-subject detection on availability.
- **Forecast false confidence** → emit confidence intervals, require a minimum history length, and label projections as estimates; never auto-remediate off a forecast.
- **Overlap with `add-interface-metric-thresholds`** → strictly complementary (dynamic vs static); do not author its `EventRule` requirements here.
- **Partition-count ceiling** → too few partitions caps stateful throughput, too many wastes consumers; partition count is hard to change later. Size N generously up front and document the repartition procedure (drain → re-key → recreate consumers).
- **Seasonal profile poisoning / cold start** → use robust statistics (median + MAD) so a past incident in the history window does not inflate the baseline; require a minimum weeks-of-history before trusting a bucket and fall back to the rolling window until warm.
- **KEDA dependency** → autoscaling requires KEDA; provide a static-replica fallback so non-KEDA installs still function (no autoscale).
- **bazel drift** → update BUILD files for new Rust deps/files (CI `bazel test` breaks even when `cargo`/`go test` pass).

## Migration Plan

1. **Track 0 first (sysmon → JetStream), behind a cutover flag:** publish sysmon to the new subject while the gRPC `StreamStatus` write still runs (shadow); switch the CNPG writer to consume from the JetStream consumer; verify parity; remove the direct write. This is reversible at each step.
2. Ship Track 1 detector behind a per-subject enable flag; validate on `otel.metrics.>` (always-live in demo) before enabling flow + sysmon subjects.
3. Add the per-interface hourly rollup migration; backfill from existing raw where available (raw is only 7 d, so forecasts ramp as CAGG history accrues).
4. Ship Track 2 forecasting cron read-only (persist + display) before wiring its verdicts into alerting.
5. Retire the bespoke netflow capacity/anomaly placeholders once the new surfaces are live.
6. Guarded auto-remediation is a separate later change; not in this one.

## Open Questions

- **RESOLVED — dedicated metrics stream:** Track 0 publishes to a dedicated `metrics` JetStream stream (`metrics.>`, `limits` retention), not the `events` stream and not the non-durable `telemetry.>`. Both sysmon (`metrics.sysmon.*`) and SNMP interface telemetry (`metrics.snmp.*`) land here. Coordinate agent-side aggregation with `update-sysmon-downsampling` so it lands on the publish path, not the gRPC path.
- Should interface anomaly baselining standardize on flow-derived bps (`flows.raw.*`) or SNMP counters (`metrics.snmp.*`) as the primary series? (Lean: flow-derived primary, SNMP secondary; both now durable.)
- Forecast model selection per resource class — linear default with seasonal (Holt-Winters) opt-in per metric class; exposed as a config knob (Decision 12). Seasonal-baseline anomaly (Tier C, Decisions 11/13) is **in scope** — open sub-question: ship V1 with the median+MAD seasonal-profile method and treat STL/Holt-Winters as the upgrade, or start with STL? (Lean: seasonal profiles first — transparent and CAGG-friendly.)
- Anomaly detector durability: ephemeral vs durable-with-`new`? (Lean: durable with `deliver_policy: new` + `inactive_threshold` for a stable name and clean reconnect, since it never needs backlog replay.)
- **Partition count for the stateful detector** — the scaling ceiling, hard to change later. What initial N balances headroom vs overhead, and is the partition token a publisher concern (subject token) or a stream subject-transform? (Lean: publisher-computed `hash(series_key) % N` token in the subject; choose N generously.)
