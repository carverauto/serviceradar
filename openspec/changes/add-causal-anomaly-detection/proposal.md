# Change: Add Causal Anomaly Detection & Capacity Forecasting

## Why

ServiceRadar can store and chart metrics, and (via `add-interface-metric-thresholds`) alert when a metric crosses an **operator-set static value**. It cannot tell that a link is behaving *abnormally relative to its own learned baseline*, nor *when* a resource will run out. The causal engine (`add-causal-engine`) reasons over **current state only** — C6 computes an instantaneous `utilization_pct = flow_bps * 100 / capacity_bps` against an 80% constant and the God-View carries a hardcoded `projected_exhaustion_at = NULL::timestamptz` placeholder awaiting projection logic. There is no statistical anomaly detection, no baselining, no seasonality, no trend/forecast primitive anywhere in the stack (the closest is SRQL `rate`, a `LAG()` derivative).

Two operator needs are unmet:

- **(a) Interface bandwidth anomaly → DoS/triage alert.** Detect when interface throughput exceeds its learned normal for a sustained period and raise a finding for triage — without the operator having to hand-tune a threshold per interface.
- **(b) Capacity planning.** Project cpu/mem/disk/interface utilization forward over a long horizon and surface *time-to-exhaustion* (disk-full ETA, link-saturation runway) so operators can act before they hit the wall.

DeepCausality — already a ServiceRadar dependency (it backs `god_view_nif` today and `rust/causal-engine`) — ships exactly the streaming primitive use case (a) needs: a `SlidingWindow` + the scale-invariant z-score control loop from Marvin Hansen's `corrective_ddos_detector` example. The "continuous stream, not Postgres" question resolves cleanly: **the live metric subjects already flow on NATS JetStream** (verified on demo, 2026-06-12), so a windowed detector consumes them per-sample and never queries hypertables for the hot path. Capacity forecasting (b) has no streaming need and no DeepCausality primitive; it is a **separate batch model** over the existing hourly continuous aggregates.

## What Changes

This change adds the **temporal/statistical layer** the current-state engine deliberately lacks, in two tracks that share one emission spine — preceded by an ingestion fix that makes the layer uniform across all metric types.

### Track 0 — Ingestion uniformity: route sysmon metrics through NATS JetStream
- **Migrate sysmon cpu/mem/disk/process metrics off the direct-to-DB gRPC path onto NATS JetStream.** Today these travel agent → gateway → core over gRPC `StreamStatus` and are written **straight into CNPG** (`push_loop_status.go:118` → `results_router.ex:241` → `sysmon_metrics_ingestor.ex:216`), bypassing the streaming backbone entirely — so they are invisible to any real-time consumer until queried back out of a hypertable. Publish them to a `telemetry.*` (or `metrics.sysmon.*`) JetStream subject and persist via the existing `event_writer` consumer pipeline, the same shape interface/flow/OTel metrics already use.
- **Establish the platform rule:** all metrics/telemetry flow through JetStream first and are never written directly to the database. Codified in `AGENTS.md` (Hard Rules) and `openspec/project.md` so future metric sources follow it by default.
- **Payoff:** cpu/mem/disk/process become live subjects, so **Track 1 real-time anomaly detection covers them too** (not just interface bandwidth), and the metric-stream asymmetry that otherwise forces capacity-only-via-CAGGs disappears.

### Track 1 — Real-time anomaly detection (DeepCausality streaming)
- **NEW `anomaly` module in `rust/causal-engine`** (the engine already hosts DeepCausality, a JetStream subscriber, the `emitter`, and `EmbeddedSrql`; it has **no windowing today** — greenfield). The module maintains per-series `SlidingWindow<ArrayStorage<f64, SIZE, CAP>>` state and runs the detector per incoming sample.
- **Detection algorithm (ported from `corrective_ddos_detector`):** scale-invariant **z-score against a clean baseline window** (sample variance, n−1), with the load-bearing *withhold-anomalous-samples-from-the-baseline* rule so a sustained flood cannot poison its own baseline and self-mask; fire on **N-sigma exceedance confirmed over M consecutive slots** (defaults N=3, M=5), reset on a clean tick. Per-series config (N, M, window size, min-samples) with sane defaults; no per-interface manual threshold required.
- **Live ingest (no new plumbing):** attach a **new durable JetStream consumer** with `filter_subjects` + `deliver_policy: NEW` for the metric subjects — interface/flow/OTel (`otel.metrics.>`, `flows.raw.netflow|sflow` on the `events` stream; `flow.attributed.>` on the `attributed_flow` stream) and the **sysmon subjects from Track 0** (cpu/mem/disk/process). The `events` stream already carries ~11 such filtered durables; one more is non-disruptive.
- **Baseline cold-start:** on startup / new series, seed the window from the **hourly CAGGs via `EmbeddedSrql`** (request/response query, never a hypertable stream) so detection is useful before a fresh window fills.
- **DeepCausality dependency upgrade (the "new Flow API"):** add `deep_causality_core` (lightweight monad + `CausalFlow` Flow DSL) and `deep_causality_data_structures` (`SlidingWindow`) at the versions that ship the Flow API (≈ `deep_causality_data_structures` 0.10.14, edition 2024). The detector is **synchronous + Markovian** (per-sample state threading); a per-sample driver replaces the example's `iterate_n`.

### Track 2 — Capacity forecasting (batch over CAGGs)
- **NEW forecasting job** (Elixir core, Oban cron) that reads the long-horizon **hourly/daily continuous aggregates** (`cpu_metrics_hourly`, `memory_metrics_hourly`, `disk_metrics_hourly`, `timeseries_metrics_hourly`, `flow_traffic_1h/1d` — ~365–395d) via SRQL and fits a trend/seasonality model (least-squares / Holt-Winters class) to project utilization forward and compute **time-to-exhaustion** per resource.
- **NEW `capacity_forecast` storage** (Ash resource + raw-SQL migration per the hypertable convention) holding per-resource projections (slope, projected value at horizon, `projected_exhaustion_at`, confidence), refreshed on the cron.
- **Fill the `projected_exhaustion_at` placeholder** that the God-View/dashboard view already expects, and extend C6's instantaneous saturation check with a forward projection (consumed, not re-authored, from the causal engine's side).
- **Per-interface rollup gap:** `timeseries_metrics_hourly` groups by `device_id/metric_type/metric_name` with **no `if_index`** — add a per-interface hourly rollup (or interface grouping) so link-saturation runway is computable; capacity denominator joins live `discovered_interfaces.speed_bps`.

### Shared emission spine (reuse, do NOT rebuild)
- Both tracks emit through the **existing causal-engine spine**: a verdict on `signals.causal.predictions.*` (new `anomaly` / `capacity_forecast` verdict kinds) → existing `CausalSignals` processor → `ocsf_events` → `StatefulAlertEngine.evaluate_events/1` (OCSF alerts, `group_by device.uid`) + God-View render. No new inbound routing, no new alert engine, no new God-View buckets. Anomaly findings carry OCSF `detection_finding` (class_uid 2004) shape; the finding/event split tracked in `add-ocsf-finding-model` applies.
- **Default posture is detect-and-alert only.** The DeepCausality `intervene` arm and the TCAS-style bounded-intervention discipline (trigger → persistence gate → already-acting interlock → clamp action to a safe envelope → audit-log override) are specified as a **future, feature-flagged guarded-remediation phase**, not enabled in V1.

### UI
- Surface anomaly findings in the existing events/alerts views; add a **capacity-forecast visualization** to the authored-dashboards panel system (extend the `:line`/`:area` visual or add a `:capacity_forecast` visual_type) and an at-risk summary tile.
- **Subsume** the two bespoke placeholders: the hardcoded "Capacity Planning" block in `netflow_live/dashboard.ex` (instantaneous, no projection) and the NetFlow "Anomaly Detection (Feature Flag)" in `settings/netflow_live/index.ex` (baseline-window/threshold-percent backend flag with no detector or viz).

## Impact

### Affected specs
- **ADDED:** `anomaly-detection` (streaming statistical detector), `capacity-forecasting` (trend/projection/exhaustion-time over CAGGs).
- **ADDED (orthogonal requirements on existing capabilities):** `observability-signals` (metric-ingestion-via-JetStream rule + sysmon migration; anomaly/forecast signal class + `events.anomaly.*`/`signals.causal.*` routing — complement to `add-interface-metric-thresholds`'s static rules, not a duplicate), `build-web-ui` (capacity-forecast / anomaly-trend visualization).

### Affected code
- **Track 0 (sysmon → JetStream):** agent publish path (`go/pkg/agent/push_loop_status.go:118` `pushSysmonStatus`), a new `telemetry.*`/`metrics.sysmon.*` publisher, a new `event_writer` processor + stream/consumer registration (`event_writer/config.ex`, `pipeline.ex`), and retirement of the direct CNPG write in `results_router.ex:241` / `observability/sysmon_metrics_ingestor.ex:216` (ingest now from the JetStream consumer). Convention codified in `AGENTS.md` + `openspec/project.md`.
- **NEW** `rust/causal-engine/src/anomaly/` (per-series `SlidingWindow` state, clean-baseline z-score detector, per-sample driver, new durable consumer wiring) + `Cargo.toml` deps `deep_causality_core`, `deep_causality_data_structures`.
- `rust/causal-engine/src/emitter.rs` — new `anomaly` / `capacity_forecast` verdict kinds on `signals.causal.predictions.*`.
- `rust/causal-engine/src/reasoner.rs` — C6 extended to consume the forward projection (instantaneous check retained).
- **NEW** Elixir core: capacity-forecasting Oban worker + `CapacityForecast` Ash resource + raw-SQL migration; per-interface hourly rollup migration (CAGG / interface grouping).
- web-ng: capacity-forecast dashboard panel/visual_type + anomaly/at-risk tiles; retire the bespoke netflow capacity/anomaly placeholders.
- **No change** to `CausalSignals` processor, `pipeline.ex` events routing, or `StatefulAlertEngine` inbound — the emission spine is reused as-is.

### Dependencies / Coordinate (declare, do NOT modify their specs)
- **`add-causal-engine`** — reuse its `signals.causal.predictions.*` → `ocsf_events` → StatefulAlertEngine + God-View spine; honor the bounded/backbone-centric topology snapshot and God-View schema_version 2 (do not add buckets). This change supplies the temporal layer it deliberately omits.
- **`add-interface-metric-thresholds`** — **complement, not overlap**: that change owns *static* operator thresholds + the unified `EventRule` (`device-inventory`, `observability-signals`); this change is *dynamic learned baselines*. Do not re-author its `EventRule`/per-metric-threshold requirements.
- **`add-device-environmental-snmp-metrics`** + **`update-sysmon-downsampling`** — upstream data producers (env SNMP into `timeseries_metrics`; agent-side windowed sysmon aggregation). Track 0 migrates the sysmon **gRPC-direct-to-DB** path onto JetStream; coordinate so the agent-side downsampling lands on the new publish path rather than the gRPC `StreamStatus` path (see design.md Decision 3).
- **`add-ocsf-finding-model`** — anomaly findings adopt its `detection_finding` finding/event split when it lands.
