## 0. Phase 0 — rectify the ingestion pipeline (prerequisite)
- [ ] 0.1 Stand up a dedicated `metrics` JetStream stream (subjects `metrics.>`), **`limits` retention — never `workqueue`** (so DB-sync and analysis consumers fan out independently), tuned for high-rate host metrics. Register in `event_writer/config.ex`.
- [ ] 0.2 **agent-gateway** publishes cpu/mem/disk/process sysmon metrics → `metrics.sysmon.*` (the agent keeps its gRPC `StreamStatus` push via `pushSysmonStatus`; **agents are NATS-denied, so the gateway is the publish boundary**), behind a cutover flag; keep the direct path in shadow.
- [ ] 0.3 Route SNMP interface telemetry (ifHCInOctets/ifHCOutOctets + `if_index`) → `metrics.snmp.*` (not durable on JetStream today).
- [ ] 0.4 New core-elx EventWriter DB-sync processor + **durable** consumer (`deliver_policy: all`, `ack_policy: explicit`, `max_deliver: -1`) consuming the metrics stream into cpu/disk/memory/process + interface tables (mirror `processors/telemetry.ex`).
- [ ] 0.5 **Retire the Go `db-event-writer`:** quick coverage audit of the six tables it owns (`ocsf_events`, `logs`, `ocsf_network_activity`, `otel_traces`, `otel_metrics`, `otel_metric_points`); then rip-and-replace — cut the double-write so core-elx is sole writer; delete `go/cmd/consumers/db-event-writer` + `go/pkg/consumers/db-event-writer` + its helm/config. (Already double-written with identical PKs, so coverage is largely there; no elaborate per-table cutover needed.)
- [ ] 0.6 **Fold the ZEN rules engine into core-elx as a Rustler NIF** (normalization runs in-process); **delete the standalone `serviceradar-zen` consumer** (`rust/consumers/zen`). Coordinate `add-event-writer-processor-contributions` passthrough engines (don't duplicate).
- [ ] 0.7 Switch sysmon/SNMP ingestion to the JetStream consumer; verify parity; remove the direct CNPG writes (`results_router.ex:241` / `observability/sysmon_metrics_ingestor.ex:216`).
- [ ] 0.8 Ingress = one publisher per telemetry type, core-elx never publishes-then-reads-back: OTLP (direct + relayed) via the `rust/otel` collector; flows via `flow-collector`; SNMP traps via `trapd`; agent gRPC status (sysmon) via agent-gateway → `metrics.*`.
- [ ] 0.9 **Eliminate the publish-then-read-back loops:**
  - (a) **OTLP relay** — funnel relayed OTLP into the `rust/otel` collector (gateway forwards the gRPC `Export*ServiceRequest`; collector chunks + publishes `otel.*` via `nats/publish.rs`); **delete core's `status_handler.ex:281` republish**. One OTLP path for direct + relayed; no bespoke publisher in gateway/core.
  - (b) **Attributed flows** — do attribution correlation **in-process / in-cluster** (libcluster/Horde routing) and write once; remove the `flow.attributed.*` NATS self-loop (`attributed_flow_joiner.ex:62` + Flows processor consuming `flow.attributed.>`).
  - (c) **Internal logs** — core-elx persists its own generated logs (sweep/health/onboarding/jobs/audit) **directly** (ZEN NIF inline if normalization needed); no publish→`.processed`→re-consume for the DB write. (May still publish to NATS for other live consumers, but the DB write does not depend on a round-trip.)
- [ ] 0.10 Coordinate with `update-sysmon-downsampling` so agent-side aggregation lands on the publish path, not gRPC. Update BUILD.bazel for new/removed Go/Elixir/Rust files.
- [ ] 0.11 **Leaf-compatibility (forward-compat, design.md Decision 16):** every ingress publisher targets a **configurable** NATS endpoint (local leaf or cloud hub), never hardcodes cloud; subjects (`metrics.>`, `otel.>`, `flows.>`) federate cleanly to the hub stream (no leaf-local-only subjects; no publisher↔stream co-location assumption); UUIDv8 stamped at edge ingress. (Edge/leaf *deployment* itself is future work, not built here.)

## 1. Phase 1 — real-time anomaly detection (core-elx Broadway + DeepCausality NIF)
- [ ] 1.1 New Rustler NIF crate exposing a **pure** `reason(context, sample) -> verdict` (no resident state); deps `deep_causality_core` + `deep_causality_data_structures` (Flow API, edition 2024); update bazel Rust deps + BUILD.
- [ ] 1.2 Implement the clean-baseline z-score in the NIF: sample variance (n−1) over the window slice, z = (x−mean)/std once filled; **withhold-anomalous-from-baseline**; fire on N-sigma over M consecutive slots (defaults N=3.0, M=5); reset on clean tick. Combine three signals (rolling / seasonal / trend) per config.
- [ ] 1.3 Broadway consumer in core-elx over the analysis consumer (separate from DB-sync; `deliver_policy: new` + `inactive_threshold`) for `metrics.sysmon.*`, `metrics.snmp.*`, `otel.metrics.>`, `flows.raw.netflow|sflow`, `flow.attributed.>`; per-subject enable flag.
- [ ] 1.4 **Context engine (Horde):** one owner per series/shard via `Horde.Registry` + `Horde.DynamicSupervisor`; single-writer-per-series; fold updates in **UUIDv8 total temporal order**; idempotent; ship immutable context to the stateless reasoner.
- [ ] 1.5 **UUIDv8** stamping at **agent-gateway ingress** (first contact = one clock domain; carry original sample time as a field) + total-order fold; tests for concurrent/out-of-order/replayed updates → deterministic context.
- [ ] 1.6 Context checkpoint to JetStream KV; Horde handoff rehydrates on node loss/scale; baseline cold-start from hourly CAGGs via SRQL; suppress findings until re-warmed.
- [ ] 1.7 Per-series config (`n_sigma`, `confirm_slots`, `window_size`, `min_samples`, seasonal sensitivity) with metric-class defaults (interface / RED / cpu / mem / disk).
- [ ] 1.8 Tests: flood that self-masks under naive baseline but stays anomalous under withhold rule; spike-vs-sustained via M-slot; cold-start seeding; Horde failover restores context without replay storm; reasoning is stateless (any pod evaluates any sample); ack-independence from DB-sync.

## 2. Capacity forecasting (Elixir core, batch)
- [ ] 2.1 New `CapacityForecast` Ash resource + raw-SQL migration (hypertable/`migrate? false` per the special-tables convention) storing per-resource slope, projected value at horizon, `projected_exhaustion_at`, confidence/interval.
- [ ] 2.2 Per-interface hourly rollup migration: `timeseries_metrics_hourly` lacks an `if_index` group key — add an interface-grouped hourly CAGG (or grouping) so link-saturation runway is computable.
- [ ] 2.3 Oban cron worker: read long-horizon CAGGs (`cpu/memory/disk/process_metrics_hourly`, `timeseries_metrics_hourly`, `flow_traffic_1h/1d`) via SRQL; fit least-squares linear trend (runway) + Holt-Winters/seasonal where seasonality matters; compute exhaustion ETA. Idempotent; string-keyed args.
- [ ] 2.4 Join the capacity denominator from live `discovered_interfaces.speed_bps` (3 d retention, no CAGG) for interface utilization%.
- [ ] 2.5 Emit a `capacity_forecast` verdict for at-risk resources via the causal-engine emission spine.
- [ ] 2.6 Tests: trend/ETA correctness on synthetic series; seasonal vs linear selection; missing-history guard (minimum length before projecting).

## 3. Emission + alert integration (reuse the existing spine)
- [ ] 3.1 core-elx emits `anomaly` + `capacity_forecast` verdicts on `signals.causal.predictions.*` with deterministic IDs; OCSF `detection_finding` (class_uid 2004) shape for anomalies. `rust/causal-engine` **consumes** these as causal evidence (the detector does not live there).
- [ ] 3.2 Confirm the existing `CausalSignals` processor + `pipeline.ex` route these into `ocsf_events` and `StatefulAlertEngine.evaluate_events/1` raises `device.uid`-grouped alerts — no inbound changes; add coverage only.
- [ ] 3.3 Align with `add-ocsf-finding-model` finding/event split when it lands (finding = durable deduped object; event references it).
- [ ] 3.4 Scaling: verify capacity scales with core-elx replica count (Horde redistributes context ownership; Broadway concurrency absorbs bursts). No standalone consumer, no external autoscaler.

## 4. Configuration (CNPG-backed, Helm-seeded, settings UI)
- [ ] 4.1 `AnomalyDetectionConfig` + forecast-config Ash resource(s) in CNPG: N-sigma, window size/duration, confirm-slots, min-samples, per-metric-class overrides (interface/RED/cpu/mem/disk), forecast horizon, warning threshold, model choice.
- [ ] 4.2 Helm chart defaults seed the config on first boot (no redeploy needed to change them afterward).
- [ ] 4.3 Engine reads config from CNPG with periodic refresh / hot-reload so edits take effect without restarting the detector.
- [ ] 4.4 Settings UI editor for the config (mirror the observability-rule-management / settings patterns); RBAC-gated.

## 5. UI (web-ng)
- [ ] 5.1 Capacity-forecast visualization in the authored-dashboards panel system: extend `:line`/`:area` `display_config` or add a `:capacity_forecast` `visual_type` (reuse `live/.../dashboard/plugins/timeseries.ex` SVG renderer).
- [ ] 5.2 Anomaly findings surfaced in `event_live`; anomaly/at-risk summary tile via the `Stats` + `rollup_stats` pattern; alerts appear in `alert_live` automatically via the spine.
- [ ] 5.3 Subsume the bespoke placeholders: hardcoded "Capacity Planning" in `live/netflow_live/dashboard.ex:581` and the NetFlow "Anomaly Detection (Feature Flag)" in `live/settings/netflow_live/index.ex:491`.
- [ ] 5.4 RBAC gates consistent with existing observability/dashboard views.

## 6. Docs / conventions
- [ ] 6.1 `AGENTS.md` Hard Rule + `openspec/project.md`: all metrics via JetStream first, never direct-to-DB (done in this proposal; keep in sync).
- [ ] 6.2 Operator docs for anomaly tuning (N-sigma/M-slot per metric class) and capacity-forecast interpretation under `docs/docs/`.
- [ ] 6.3 Note the future feature-flagged guarded-remediation phase (TCAS 5-gate discipline) as a follow-up change; not implemented here.

## 7. Validation
- [ ] 7.1 `openspec validate add-causal-anomaly-detection --strict` passes.
- [ ] 7.2 Validate live on `otel.metrics.>` (always-live in demo) before enabling flow/sysmon subjects.
- [ ] 7.3 `bazel test` green for the new Rust module + BUILD updates; Elixir quality contract green.
