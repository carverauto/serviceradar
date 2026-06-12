# Change: Add Causal Anomaly Detection & Capacity Forecasting

## Why

ServiceRadar can store and chart metrics, and (via `add-interface-metric-thresholds`) alert when a metric crosses an **operator-set static value**. It cannot tell that a link is behaving *abnormally relative to its own learned baseline*, nor *when* a resource will run out. The causal engine (`add-causal-engine`) reasons over **current state only** — C6 computes an instantaneous `utilization_pct = flow_bps * 100 / capacity_bps` against an 80% constant and the God-View carries a hardcoded `projected_exhaustion_at = NULL::timestamptz` placeholder awaiting projection logic. There is no statistical anomaly detection, no baselining, no seasonality, no trend/forecast primitive anywhere in the stack (the closest is SRQL `rate`, a `LAG()` derivative).

Two operator needs are unmet:

- **(a) Interface bandwidth anomaly → DoS/triage alert.** Detect when interface throughput exceeds its learned normal for a sustained period and raise a finding for triage — without the operator having to hand-tune a threshold per interface.
- **(b) Capacity planning.** Project cpu/mem/disk/interface utilization forward over a long horizon and surface *time-to-exhaustion* (disk-full ETA, link-saturation runway) so operators can act before they hit the wall.

DeepCausality — already a ServiceRadar dependency (it backs `god_view_nif` today and `rust/causal-engine`) — ships exactly the streaming primitive use case (a) needs: a `SlidingWindow` + the scale-invariant z-score control loop from Marvin Hansen's `corrective_ddos_detector` example. The "continuous stream, not Postgres" question resolves cleanly: **the live metric subjects already flow on NATS JetStream** (verified on demo, 2026-06-12), so a windowed detector consumes them per-sample and never queries hypertables for the hot path. Capacity forecasting (b) has no streaming need and no DeepCausality primitive; it is a **separate batch model** over the existing hourly continuous aggregates.

## What Changes

This change adds the **temporal/statistical layer** the current-state engine deliberately lacks, in two tracks that share one emission spine — preceded by an ingestion fix that makes the layer uniform across all metric types.

### Phase 0 — Rectify the ingestion pipeline (prerequisite)
The current pipeline is a **half-finished migration** (verified in code, design.md Decision 15); this phase cleans it up before anything is built on top:
- **Stand up a dedicated `metrics` JetStream stream** (subjects `metrics.>`, **`limits` retention — never `workqueue`**) as the durable home for metrics, and route onto it every metric source not already durably streamed:
  - **Sysmon cpu/mem/disk/process** — today written **straight into CNPG** over gRPC `StreamStatus` (`push_loop_status.go:118` → `results_router.ex:241` → `sysmon_metrics_ingestor.ex:216`), bypassing the backbone. Publish to `metrics.sysmon.*`; retire the direct CNPG write.
  - **SNMP interface telemetry** — verified **not durable on JetStream today** (`telemetry.>` is on no stream). Route interface counters (ifHCInOctets/ifHCOutOctets + `if_index`) to `metrics.snmp.*`.
- **Retire the Go `db-event-writer`; core-elx EventWriter becomes the SOLE CNPG writer.** Today **both** write `otel_traces`/`otel_metrics`/`otel_metric_points` (and overlapping `ocsf_events`/`logs`) — a double-write surviving only on identical PKs + `ON CONFLICT DO NOTHING` as a migration bridge (`otelmetricpoints.go:1-31`). An archived `rewrite-db-event-writer-elixir` already intended this; **finish it** (delete the Go consumer + its config/helm after parity is verified).
- **`zen` stays as the normalization/rules engine but feeds core-elx, not a separate persister.** The raw→`.processed` step (`logs.* → zen → logs.*.processed`) keeps normalizing; core-elx consumes the normalized subjects and is the only thing that writes CNPG. (May fold into EventWriter passthrough engines per `add-event-writer-processor-contributions` — coordinate, don't duplicate.)
- **agent-gateway is the single ingress** that publishes all telemetry raw to JetStream; everything downstream consumes from there. No gRPC-direct-to-DB, no parallel persisters.
- **Two-consumer fan-out (not a ring buffer):** both consume the **raw** stream **in parallel** with `limits` retention + independent cursors — **DB-sync** (core-elx → CNPG) and **real-time analysis** (the anomaly path). An ack on one never affects the other; analysis never waits on the DB. Ring buffer rejected (µs-only; a DoS isn't that fast, ~5 s first-response is fine).
- **Platform rule** codified in `AGENTS.md` + `openspec/project.md`: all metrics flow through JetStream first, never written directly to the database.

### Phase 1 — Real-time anomaly detection (core-elx Broadway + DeepCausality NIF)
- **Detector = a core-elx Broadway consumer routing each sample into a DeepCausality Rustler NIF** (the NIF is a **pure reasoner** `reason(context, sample) -> verdict`, no resident state). core-elx is already a libcluster/Horde cluster — the right substrate to scale (design.md Decision 1). The standalone `rust/causal-engine` **consumes** the verdicts as causal evidence rather than hosting the detector.
- **Detection algorithm (ported from `corrective_ddos_detector`):** scale-invariant **z-score against a clean baseline window** (sample variance, n−1), with the load-bearing *withhold-anomalous-samples-from-the-baseline* rule so a sustained flood cannot poison its own baseline and self-mask; fire on **N-sigma exceedance confirmed over M consecutive slots** (defaults N=3, M=5), reset on a clean tick. No per-interface manual threshold required.
- **Separate context from reasoning (the scaling model):** reasoning is stateless → round-robin across all pods. The stateful **context engine** (per-series window/seasonal/counters) is confined and made deterministic via **KSUID total temporal order** (fold updates in time order; idempotent → restart-safe), owned by **Horde** (one owner per series/shard, location-transparent, failover), checkpointed to **JetStream KV** (design.md Decision 14).
- **DeepCausality dependency upgrade (the "new Flow API"):** add `deep_causality_core` (monad + `CausalFlow` Flow DSL) and `deep_causality_data_structures` (`SlidingWindow`), ≈ `deep_causality_data_structures` 0.10.14, edition 2024. Synchronous + Markovian per-sample reasoning.
- **Baseline cold-start:** seed a new/empty series' context from the **hourly CAGGs via SRQL** (request/response, never a hypertable stream).
- **Restart survival:** `deliver_policy: new` + per-series context checkpoint to KV + CAGG cold-start; findings suppressed until re-warmed (design.md Decision 10).
- **Baseline is short by design:** a bounded rolling window (minutes–tens of minutes) for *sudden* spikes; the "exceeded for X period" is the separate M-slot knob. Slow ramps → Phase 2.
- **Seasonal-aware detection (in scope):** per-series **day-of-week × hour-of-day** profiles (168 buckets, robust median + MAD) computed in batch from the hourly CAGGs (~56 weeks available) and **consulted by the detector per-sample** — so "is this abnormal for a Tuesday 9am?" is answered in real time. Three combined signals: rolling-window (sudden) + seasonal-profile (off-pattern) + trend (slow exhaustion). STL/Holt-Winters upgrade path (design.md Decision 13).
- **KEDA** autoscales core-elx **pod count** on JetStream consumer lag; Broadway internal concurrency scales within a pod (design.md Decision 14).

### Phase 2 — Capacity forecasting (batch over CAGGs)
- **NEW forecasting job** (Elixir core, Oban cron) that reads the long-horizon **hourly/daily continuous aggregates** (`cpu_metrics_hourly`, `memory_metrics_hourly`, `disk_metrics_hourly`, `timeseries_metrics_hourly`, `flow_traffic_1h/1d` — ~365–395d) via SRQL and fits a trend/seasonality model (least-squares / Holt-Winters class) to project utilization forward and compute **time-to-exhaustion** per resource.
- **NEW `capacity_forecast` storage** (Ash resource + raw-SQL migration per the hypertable convention) holding per-resource projections (slope, projected value at horizon, `projected_exhaustion_at`, confidence), refreshed on the cron.
- **Fill the `projected_exhaustion_at` placeholder** that the God-View/dashboard view already expects, and extend C6's instantaneous saturation check with a forward projection (consumed, not re-authored, from the causal engine's side).
- **Per-interface rollup gap:** `timeseries_metrics_hourly` groups by `device_id/metric_type/metric_name` with **no `if_index`** — add a per-interface hourly rollup (or interface grouping) so link-saturation runway is computable; capacity denominator joins live `discovered_interfaces.speed_bps`.

### Shared emission spine (reuse, do NOT rebuild)
- Both detectors emit through the **existing causal-engine spine**: a verdict on `signals.causal.predictions.*` (new `anomaly` / `capacity_forecast` verdict kinds) → existing `CausalSignals` processor → `ocsf_events` → `StatefulAlertEngine.evaluate_events/1` (OCSF alerts, `group_by device.uid`) + God-View render. No new inbound routing, no new alert engine, no new God-View buckets. Anomaly findings carry OCSF `detection_finding` (class_uid 2004) shape; the finding/event split tracked in `add-ocsf-finding-model` applies.
- **Default posture is detect-and-alert only.** The DeepCausality `intervene` arm and the TCAS-style bounded-intervention discipline (trigger → persistence gate → already-acting interlock → clamp action to a safe envelope → audit-log override) are specified as a **future, feature-flagged guarded-remediation phase**, not enabled in V1.

### UI + configuration
- **Tuning knobs live in CNPG + settings UI, seeded from Helm** (design.md Decision 12): N-sigma, window size/duration, confirm-slots ("for X period"), min-samples, per-metric-class overrides (interface/RED/cpu/mem/disk), forecast horizon, warning threshold, model choice. Helm provides first-boot defaults; operators edit in the settings UI; the engine reads config from CNPG with periodic refresh so changes apply without a redeploy. (Stream/consumer retention + subjects stay Helm/infra-managed.)
- Surface anomaly findings in the existing events/alerts views; add a **capacity-forecast visualization** to the authored-dashboards panel system (extend the `:line`/`:area` visual or add a `:capacity_forecast` visual_type) and an at-risk summary tile.
- **Subsume** the two bespoke placeholders: the hardcoded "Capacity Planning" block in `netflow_live/dashboard.ex` (instantaneous, no projection) and the NetFlow "Anomaly Detection (Feature Flag)" in `settings/netflow_live/index.ex` (baseline-window/threshold-percent backend flag with no detector or viz).

## Impact

### Affected specs
- **ADDED:** `anomaly-detection` (streaming statistical detector + seasonal + scalable context/reasoning), `capacity-forecasting` (trend/projection/exhaustion-time over CAGGs).
- **ADDED (orthogonal requirements on existing capabilities):** `observability-signals` (Phase 0: single ingress via agent-gateway, single CNPG writer / `db-event-writer` retirement, metric-ingestion-via-JetStream, total-order KSUID context engine; anomaly/forecast signal routing — complement to `add-interface-metric-thresholds`'s static rules, not a duplicate), `build-web-ui` (capacity-forecast / anomaly-trend visualization + detector config UI).

### Affected code
- **Phase 0 (ingestion rectification):** new `metrics` JetStream stream (`limits` retention) in `event_writer/config.ex`/`pipeline.ex`; sysmon publisher (`go/pkg/agent/push_loop_status.go:118` `pushSysmonStatus`) → `metrics.sysmon.*`; SNMP interface telemetry → `metrics.snmp.*`; new core-elx EventWriter processor(s) consuming the metrics stream into CNPG; **delete the Go `db-event-writer`** (`go/cmd/consumers/db-event-writer`, `go/pkg/consumers/db-event-writer`, its helm/config) once core-elx parity is verified; remove the direct CNPG writes (`results_router.ex:241` / `sysmon_metrics_ingestor.ex:216`); confirm `zen` (`rust/consumers/zen`) feeds core-elx; agent-gateway single-ingress publish. Convention codified in `AGENTS.md` + `openspec/project.md`.
- **NEW** core-elx anomaly path: a Broadway consumer + DeepCausality **Rustler NIF** (pure `reason(context, sample) -> verdict`); a **Horde**-managed per-series/shard context engine (KSUID total-order fold, JetStream-KV checkpoint); `Cargo.toml` deps `deep_causality_core`, `deep_causality_data_structures` for the NIF crate.
- **NEW** Elixir core: `AnomalyDetectionConfig` / forecast-config Ash resource (CNPG-backed, Helm-seeded, hot-reloaded) edited in settings UI; `SeasonalProfile` resource + batch job computing day-of-week × hour-of-day profiles (median+MAD) from the hourly CAGGs.
- **NEW** deploy: KEDA `ScaledObject`(s) autoscaling core-elx pod count on JetStream consumer lag; Helm wiring + KEDA documented as a k8s install requirement (static-replica fallback).
- `rust/causal-engine` — **consumes** the new `anomaly`/`capacity_forecast` verdicts as causal evidence; C6 extended to consume the forward projection (instantaneous check retained). (Detector does not live here.)
- **NEW** Elixir core: capacity-forecasting Oban worker + `CapacityForecast` Ash resource + raw-SQL migration; per-interface hourly rollup migration (CAGG / interface grouping).
- web-ng: capacity-forecast dashboard panel/visual_type + anomaly/at-risk tiles; retire the bespoke netflow capacity/anomaly placeholders.
- Emission: new `anomaly`/`capacity_forecast` verdict kinds on `signals.causal.predictions.*`; **No change** to `CausalSignals` processor, `pipeline.ex` events routing, or `StatefulAlertEngine` inbound — the emission spine is reused as-is.

### Dependencies / Coordinate (declare, do NOT modify their specs)
- **KEDA** — required for consumer autoscaling (already installed and in use in the cluster: keda-operator + ScaledObjects). Becomes a documented ServiceRadar k8s install requirement; non-KEDA installs fall back to static replicas.
- **`add-causal-engine`** — reuse its `signals.causal.predictions.*` → `ocsf_events` → StatefulAlertEngine + God-View spine; honor the bounded/backbone-centric topology snapshot and God-View schema_version 2 (do not add buckets). This change supplies the temporal layer it deliberately omits.
- **`add-interface-metric-thresholds`** — **complement, not overlap**: that change owns *static* operator thresholds + the unified `EventRule` (`device-inventory`, `observability-signals`); this change is *dynamic learned baselines*. Do not re-author its `EventRule`/per-metric-threshold requirements.
- **`add-device-environmental-snmp-metrics`** + **`update-sysmon-downsampling`** — upstream data producers (env SNMP into `timeseries_metrics`; agent-side windowed sysmon aggregation). Phase 0 migrates the sysmon **gRPC-direct-to-DB** path onto JetStream; coordinate so the agent-side downsampling lands on the new publish path rather than the gRPC `StreamStatus` path (see design.md Decision 15).
- **`rewrite-db-event-writer-elixir` (archived)** — Phase 0 **finishes** this migration by retiring the Go `db-event-writer` and making core-elx EventWriter the sole CNPG writer.
- **`add-event-writer-processor-contributions`** — coordinate `zen` consolidation / EventWriter passthrough engines so Phase 0 does not duplicate that work.
- **`add-ocsf-finding-model`** — anomaly findings adopt its `detection_finding` finding/event split when it lands.
