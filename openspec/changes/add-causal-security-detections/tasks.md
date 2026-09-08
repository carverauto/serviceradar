## 1. Security Context hydration (`rust/causal-context`)

- [ ] 1.1 Map asset criticality / CVE exposure / identity privilege from `ocsf_devices` + `vulnerability_*` + auth tables onto `Datoid` contextoids, keyed by canonical `sr:`-prefixed IDs (`RuntimeGraph.canonical_runtime_id/1`).
- [ ] 1.2 Project `platform_graph` (AGE) topology position / segment / reachability onto `Spaceoid` contextoids; drive freeze/unfreeze from `on_topology_change`.
- [ ] 1.3 Hydrate time-of-day baselines, dwell windows, and beacon periodicity from Timescale rollups onto `Tempoid` contextoids.
- [ ] 1.4 Hydrate bounded IOC/threat-intel indicators onto `Symboid` contextoids only within the active `expires_at` window; enforce a Context memory ceiling.
- [ ] 1.5 Keep bulk IOC/CIDR matching in-DB (existing GIST containment index + `ip_threat_intel_cache`) surfaced as an L1 `Observation`; do NOT materialize `threat_intel_*` / `otx_retrohunt_*` wholesale as Symboids.
- [ ] 1.6 Give fast-changing Datoid/Symboid state (CVE, IOC feeds) a refresh cadence separate from the topology freeze; document the cadence and ceiling in `causal-config`.

## 2. Kill-chain `CausaloidGraph` (`rust/causal-reasoning`)

- [ ] 2.1 Build one `CausaloidGraph` per incident hypothesis (single entity or correlated cluster) so the propagating `V` is about one incident.
- [ ] 2.2 Wire kill-chain edges (recon → initial-access → execution → {c2, lateral} → …); `freeze()` before reasoning.
- [ ] 2.3 Evaluate via `evaluate_subgraph_from_cause` (topological forward propagation over the frozen hypergraph) with reconvergent LUB `join` (`SecVerdict::join` = idempotent LUB, §4.2).
- [ ] 2.4 Ensure precursor nodes (recon/scan) fire before impact nodes; keep next-stage prediction out of V1 (Phase-2, needs calibrated stage priors).

## 3. V1 security causaloid catalog (`rust/causal-causaloids`)

- [ ] 3.1 S1 — C2 beaconing: fuse DNS(DGA) ∧ flow(periodicity) ∧ threat-intel ∧ host(Falco) into one verdict; stage C2 / ATT&CK T1071, T1568.
- [ ] 3.2 S2 — data exfiltration: fuse flow(large egress) ∧ S1 prior; stage Exfil / T1041, T1567.
- [ ] 3.3 S4 — exposed CVE under live exploitation: fuse the EXISTING KEV ranking (`endpoint_vulnerability_matches`) ∧ scan(exposure) ∧ host(runtime); stage Exec / T1190 (increment is the fusion, not the ranking).
- [ ] 3.4 S5 — route diversion / MITM: fuse BGP(anomaly) ∧ flow(unexpected AS) ∧ MTR(path change) from BMP analytics + MTR consensus; stage C2/Collection / T1557.
- [ ] 3.5 S6 — recon/scanning precursor: fuse scan_activity ∧ topology exposure; stage Recon / T1595.
- [ ] 3.6 Author each causaloid as a §4.3 two-step fusion node (collapse correlated clusters, then combine independent clusters); tag `EvidenceRef.attck`.
- [ ] 3.7 Explicitly exclude S3 (lateral movement) and S7 (credential attack) from V1 (blocked on host-auth ingest; coordinate `add-identity-asset-flow-bridge`).

## 4. Detect→respond CSM wiring (`rust/causal-reasoning`)

- [ ] 4.1 Reconstruct a fused `Uncertain<f64>` from the graph verdict and test it with an `UncertainParameter` (SPRT; `max_samples` ≈ 200).
- [ ] 4.2 Build a `CSM` from `CausalState::new(entity_id, …)` + `CausalAction::new(fn, …)`; thread entity/verdict through `CausalState` and a static registry read by a non-capturing `fn` (no capturing closure — `CausalAction` takes a bare `fn` pointer).
- [ ] 4.3 Trigger the action from `is_active()` (SPRT) via `eval_single_state`; V1 dispatches `alert_only` (actuation deferred to `add-causal-mitigation`).

## 5. Prediction emission (`rust/causal-emit`)

- [ ] 5.1 Publish verdicts on `signals.analytics.predictions.{device_uid|incident_id}` using `ServiceRadar.Observability.CausalPredictionSubject` (`@subject_root "signals.analytics.predictions"`); NEVER the legacy `signals.causal.*`.
- [ ] 5.2 Derive DETERMINISTIC prediction IDs from stable inputs (canonical `sr:` ID + causaloid identifier + snapshot revision) so re-reasoning yields identical IDs and re-emit is idempotent.
- [ ] 5.3 Populate the OCSF envelope with the canonical `sr:`-prefixed device id at the `device.uid` group position.

## 6. God-View / StatefulAlertEngine integration (Elixir)

- [ ] 6.1 Confirm `AnalyticsSignals` (`event_writer/processors/analytics_signals.ex`) + `pipeline.ex` route `signals.analytics.predictions.*` into `ocsf_events` (inbound path already exists; no new inbound plumbing).
- [ ] 6.2 Author at least one `stateful_alert_rule` with `group_by ["device.uid"]` targeting causal-prediction events so verdicts re-enter `StatefulAlertEngine.evaluate_events/1` as `device.uid`-grouped alerts (OCSF `class_uid` 1008).
- [ ] 6.3 Map normalized verdicts deterministically to the God-View 4 buckets (`root_cause | affected | healthy | unknown`) without altering the snapshot contract; handle endpoint-cluster summary nodes.

## 7. L1 state-feed ingest — carried over from `add-causal-security-foundation`

Deferred in the foundation milestone (runtime/infra; not locally verifiable) and landed here, where live
Observations are first needed. Fulfills the archived `causal-security-observations` "State-Change Feed
Consumption" requirement.

- [ ] 7.1 Enable `STATE_CHANGE_EVENTS_ENABLED` for the app-level `signals.state.<table>` publisher (`event_writer/state_change_publisher.ex`) and provision the `signals.state.>` JetStream stream/consumer. Ops/config change on the running system — NOT pgoutput CDC.
- [ ] 7.2 Implement the live `signals.state.<table>` NATS-backed `ObservationSource` in `rust/causal-ingest` (behind the `nats` feature), surfacing each transition as an `Observation` keyed to the entity's canonical `sr:`-prefixed id and reusing the Phase-0 `build_observation` calibration path. Replaces the `InMemorySource` seam for live use.
- [ ] 7.3 Integration-test an `ocsf_devices` transition on `signals.state.ocsf_devices` mapping to an `Observation` and feeding Context hydration (§1).

## 8. Validation

- [ ] 8.1 Unit-test the kill-chain graph: recon fires before exfil; reconvergent `join` is order-invariant (LUB).
- [ ] 8.2 Integration-test one prediction end-to-end: a published `signals.analytics.predictions.*` verdict becomes a `device.uid`-grouped alert with no new inbound plumbing.
- [ ] 8.3 Test bounded-IOC policy: an IOC match is computed in-DB (GIST containment), not by materializing all indicators in memory; Context stays under the memory ceiling.
- [ ] 8.4 Run `openspec validate add-causal-security-detections --strict` and fix any errors.
