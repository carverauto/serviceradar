# Change: V1 cross-domain security detections: kill-chain graph, S1/S2/S4/S5/S6, prediction emission

## Why

The causal engine chassis (`add-causal-engine`) and the security foundation (`add-causal-security-foundation`) give us a fused pod, ingestion feeds, a `SecVerdict` lattice, and per-domain confidence — but no actual security reasoning. This change lands the first cross-domain intrusion detections: a frozen per-incident kill-chain `CausaloidGraph`, the shippable V1 causaloid catalog (S1/S2/S4/S5/S6), and a detect→respond CSM whose verdicts close the automation loop by re-entering `StatefulAlertEngine` as alerts and driving the God-View render — the one thing no single-domain tool at the edge can do.

## What Changes

- **Security Context hypergraph (Layer 2):** hydrate DeepCausality `Contextoid`s so an `Observation` is judged against a world model — asset criticality / CVE exposure / identity privilege as `Datoid`, `platform_graph` topology reachability as `Spaceoid`, time-of-day/beacon-periodicity baselines as `Tempoid`, IOC indicators as `Symboid` — landing in `rust/causal-context`.
- **Bounded IOC hydration:** `threat_intel_*` / `otx_retrohunt_*` MUST NOT be materialized wholesale as Symboids. IOC/CIDR matching stays in-DB (existing GIST containment + `ip_threat_intel_cache`) as an L1 Observation, with a Context memory ceiling and a fast-changing Datoid/Symboid refresh cadence **separate** from the topology freeze.
- **Kill-chain `CausaloidGraph`:** one graph per incident hypothesis (single entity or correlated cluster), `freeze()` before reasoning, `evaluate_subgraph_from_cause` for topological forward propagation, reconvergent LUB `join` (§4.2), precursor nodes (recon/scan) firing before impact — early detection in V1.
- **V1 security causaloid catalog (S1/S2/S4/S5/S6):** cross-domain fusion nodes in `rust/causal-causaloids` — S1 C2 beaconing (T1071, T1568), S2 data exfiltration (T1041, T1567), S4 exposed-CVE-under-live-exploitation (T1190 — fusing the **existing** KEV ranking with scan-exposure and host-runtime), S5 route diversion / MITM (T1557), S6 recon/scanning precursor (T1595). Each builds on today's schema subject to §2 collector provisioning. S3/S7 are explicitly out of scope (blocked on host-auth ingest).
- **Detect→respond via CSM:** wire the SPRT-tested verdict into a `CSM` (`CausalState` + `CausalAction`). Because `CausalAction::new` takes a bare `fn` pointer that cannot capture, entity/verdict is threaded through `CausalState` and a static registry read by a non-capturing `fn`, not a capturing closure. V1 fires `alert_only` (actuation is deferred to `add-causal-mitigation`).
- **Prediction emission + automation-loop closure:** a greenfield producer (`rust/causal-emit`) publishes verdicts on `signals.analytics.predictions.{device_uid|incident_id}` (subject via `ServiceRadar.Observability.CausalPredictionSubject`) with deterministic prediction IDs and canonical `sr:`-prefixed IDs. The existing `AnalyticsSignals` processor routes them into `ocsf_events`, from which they (a) re-enter `StatefulAlertEngine.evaluate_events/1` as `device.uid`-grouped alerts (OCSF `class_uid` 1008) and (b) drive the God-View 4-bucket render. No new inbound plumbing; only the producer half.

## Impact

- **Affected specs:** `causal-security-context` (ADDED), `causal-security-detections` (ADDED).
- **Affected code:**
  - NEW `rust/causal-context` (Security Context hydration; bounded-IOC policy), `rust/causal-causaloids` (S1/S2/S4/S5/S6 + kill-chain topology), `rust/causal-reasoning` (graph eval + CSM wiring), `rust/causal-emit` (verdict → `signals.analytics.predictions.*`) — flat `rust/causal-*` root-workspace members mirroring `rust/anomaly-*`.
  - `elixir/serviceradar_core/lib/serviceradar/event_writer/processors/analytics_signals.ex` and `event_writer/pipeline.ex` — consume the NEW `signals.analytics.predictions.*` verdicts (inbound path already exists; only the producer is new).
  - `observability/stateful_alert_engine.ex` (`evaluate_events/1`) — at least one `device.uid`-grouped stateful-alert rule targeting causal-prediction events.
  - God-View render path — verdict-to-bucket mapping (no snapshot-contract change).
  - IOC/CIDR matching stays in-DB against `threat_intel_*` / `ip_threat_intel_cache` (GIST containment); no wholesale hydration.
- **Dependencies / Coordinate:**
  - **EXTENDS** the settled `add-causal-engine` chassis (fused `rust/causal-engine`, three ingestion feeds, emission/automation loop, `god_view_nif` demotion, reliability causaloids C1–C13) — inherit its infrastructure; do NOT redefine it. Note `add-causal-engine`'s `causal-prediction-signals` spec still uses the stale `signals.causal.*`/`CausalSignals` names; this change uses the corrected `signals.analytics.predictions.>` → `AnalyticsSignals` names verified against the repo.
  - **DEPENDS ON** `add-causal-security-foundation` (Milestone 1): the `SecVerdict` lattice + `Verdict` impl, the `Observation`/`ObservationSource` model, per-domain confidence construction, and the crate scaffold this milestone builds on.
  - **Coordinate (deltas NOT authored here):** `add-identity-asset-flow-bridge` (unblocks S3 via the identity↔asset↔flow bridge), `add-causal-mitigation` (the shadow-first policy table + northbound actuation the CSM will eventually dispatch to; V1 here is `alert_only`), `add-causal-detection-feedback` (analyst TP/FP labeling + variance calibration that tunes these detections' precision/recall).
