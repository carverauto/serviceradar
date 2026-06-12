## 0. Ingestion uniformity — sysmon metrics onto JetStream (prerequisite)
- [ ] 0.1 Define the sysmon metric subject + JetStream stream/consumer config (lean: dedicated `metrics.sysmon.*`; tune retention/limits for high-rate host metrics). Register in `event_writer/config.ex` stream registry.
- [ ] 0.2 Add an agent-side publisher for cpu/mem/disk/process sysmon metrics to the new subject (`go/pkg/agent/push_loop_status.go` `pushSysmonStatus` path), behind a cutover flag; keep the gRPC `StreamStatus` write running in shadow.
- [ ] 0.3 Add a new `event_writer` processor that consumes the sysmon subject and writes cpu/disk/memory/process metrics into CNPG (mirror `processors/telemetry.ex`); add the durable consumer (`filter_subjects` + `deliver_policy: NEW`).
- [ ] 0.4 Switch core ingestion to the JetStream consumer; verify parity with the gRPC path; then retire the direct CNPG write in `results_router.ex:241` / `observability/sysmon_metrics_ingestor.ex:216`.
- [ ] 0.5 Coordinate with `update-sysmon-downsampling` so agent-side windowed aggregation lands on the publish path, not the gRPC path.
- [ ] 0.6 Update BUILD.bazel for any new Go/Elixir files.

## 1. Real-time anomaly detection (`rust/causal-engine`)
- [ ] 1.1 Add `deep_causality_core` + `deep_causality_data_structures` to `rust/causal-engine/Cargo.toml` (Flow API versions, edition 2024); update bazel Rust deps (`scripts/update-rust-bazel-deps.sh`).
- [ ] 1.2 New `src/anomaly/` module: per-series `SlidingWindow<ArrayStorage<f64, SIZE, CAP>>` registry with a per-series cap + LRU eviction of idle series.
- [ ] 1.3 Implement the clean-baseline z-score detector: sample variance (n−1) over `.slice()`, z = (x−mean)/std once `filled()`; **withhold-anomalous-from-baseline** (push only when not flagged); fire on N-sigma over M consecutive slots (defaults N=3.0, M=5); reset on clean tick.
- [ ] 1.4 Per-sample driver invoked from the JetStream subscriber callback (synchronous/Markovian; replaces the example's `iterate_n`); per-series config (`n_sigma`, `confirm_slots`, `window_size`, `min_samples`) with metric-class defaults (interface vs RED vs sysmon).
- [ ] 1.5 New durable consumer wiring for the metric subjects: `otel.metrics.>`, `flows.raw.netflow|sflow`, `flow.attributed.>`, and the Track 0 sysmon subject; per-subject enable flag.
- [ ] 1.6 Baseline cold-start: seed a new/empty window from the hourly CAGG for that series via `EmbeddedSrql` (request/response), then switch to live updates.
- [ ] 1.7 Tests: synthetic flood that self-masks under naive baseline but stays anomalous under withhold rule; spike-vs-sustained discrimination via M-slot gate; cold-start seeding.

## 2. Capacity forecasting (Elixir core, batch)
- [ ] 2.1 New `CapacityForecast` Ash resource + raw-SQL migration (hypertable/`migrate? false` per the special-tables convention) storing per-resource slope, projected value at horizon, `projected_exhaustion_at`, confidence/interval.
- [ ] 2.2 Per-interface hourly rollup migration: `timeseries_metrics_hourly` lacks an `if_index` group key — add an interface-grouped hourly CAGG (or grouping) so link-saturation runway is computable.
- [ ] 2.3 Oban cron worker: read long-horizon CAGGs (`cpu/memory/disk/process_metrics_hourly`, `timeseries_metrics_hourly`, `flow_traffic_1h/1d`) via SRQL; fit least-squares linear trend (runway) + Holt-Winters/seasonal where seasonality matters; compute exhaustion ETA. Idempotent; string-keyed args.
- [ ] 2.4 Join the capacity denominator from live `discovered_interfaces.speed_bps` (3 d retention, no CAGG) for interface utilization%.
- [ ] 2.5 Emit a `capacity_forecast` verdict for at-risk resources via the causal-engine emission spine.
- [ ] 2.6 Tests: trend/ETA correctness on synthetic series; seasonal vs linear selection; missing-history guard (minimum length before projecting).

## 3. Emission + alert integration (reuse the existing spine)
- [ ] 3.1 Add `anomaly` + `capacity_forecast` verdict kinds to `rust/causal-engine` `emitter` on `signals.causal.predictions.*` with deterministic IDs; OCSF `detection_finding` (class_uid 2004) shape for anomalies.
- [ ] 3.2 Confirm the existing `CausalSignals` processor + `pipeline.ex` route these into `ocsf_events` and `StatefulAlertEngine.evaluate_events/1` raises `device.uid`-grouped alerts — no inbound changes; add coverage only.
- [ ] 3.3 Align with `add-ocsf-finding-model` finding/event split when it lands (finding = durable deduped object; event references it).

## 4. UI (web-ng)
- [ ] 4.1 Capacity-forecast visualization in the authored-dashboards panel system: extend `:line`/`:area` `display_config` or add a `:capacity_forecast` `visual_type` (reuse `live/.../dashboard/plugins/timeseries.ex` SVG renderer).
- [ ] 4.2 Anomaly findings surfaced in `event_live`; anomaly/at-risk summary tile via the `Stats` + `rollup_stats` pattern; alerts appear in `alert_live` automatically via the spine.
- [ ] 4.3 Subsume the bespoke placeholders: hardcoded "Capacity Planning" in `live/netflow_live/dashboard.ex:581` and the NetFlow "Anomaly Detection (Feature Flag)" in `live/settings/netflow_live/index.ex:491`.
- [ ] 4.4 RBAC gates consistent with existing observability/dashboard views.

## 5. Docs / conventions
- [ ] 5.1 `AGENTS.md` Hard Rule + `openspec/project.md`: all metrics via JetStream first, never direct-to-DB (done in this proposal; keep in sync).
- [ ] 5.2 Operator docs for anomaly tuning (N-sigma/M-slot per metric class) and capacity-forecast interpretation under `docs/docs/`.
- [ ] 5.3 Note the future feature-flagged guarded-remediation phase (TCAS 5-gate discipline) as a follow-up change; not implemented here.

## 6. Validation
- [ ] 6.1 `openspec validate add-causal-anomaly-detection --strict` passes.
- [ ] 6.2 Validate live on `otel.metrics.>` (always-live in demo) before enabling flow/sysmon subjects.
- [ ] 6.3 `bazel test` green for the new Rust module + BUILD updates; Elixir quality contract green.
