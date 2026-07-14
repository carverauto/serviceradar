# causal-security-detections Specification (delta for add-causal-security-detections)

This delta adds the Layer-3 cross-domain security reasoning: a per-incident kill-chain `CausaloidGraph`,
the V1 causaloid catalog (S1/S2/S4/S5/S6), the detect→respond CSM, and verdict emission that closes the
automation loop. It EXTENDS the `add-causal-engine` chassis and DEPENDS ON `add-causal-security-foundation`
for the `SecVerdict` lattice and per-domain confidence. S3/S7 are out of scope (blocked on host-auth
ingest; coordinate `add-identity-asset-flow-bridge`); auto-mitigation actuation is out of scope
(coordinate `add-causal-mitigation`).

## ADDED Requirements

### Requirement: Kill-Chain Causaloid Graph

The engine SHALL evaluate one `CausaloidGraph` per incident hypothesis (a single canonical entity or one
correlated cluster) so the propagating verdict `V` describes exactly one incident. The graph MUST be
`freeze()`d before reasoning, evaluated with `evaluate_subgraph_from_cause` (topological forward
propagation over the frozen hypergraph), and MUST reconverge branches using the idempotent LUB `join`
(`SecVerdict::join` = `stage.max` / `confidence.max` / `severity.max` + evidence union). Corroboration
fusion (noisy-OR / inverse-variance) MUST live inside a fusion node, NOT in `join`, to preserve the
lattice laws and avoid diamond double-counting. Precursor (recon/scan) nodes SHALL fire before impact
nodes; forward-propagated next-stage prediction is out of scope for V1.

#### Scenario: Recon fires before exfil

- **GIVEN** a frozen kill-chain `CausaloidGraph` with a recon precursor node upstream of an exfil node
- **WHEN** the engine evaluates the graph from an initial-access cause via `evaluate_subgraph_from_cause`
- **THEN** the recon precursor node SHALL be evaluated before the exfil node in topological order
- **AND** the emitted verdict's `stage` SHALL reflect the earliest observed precursor, enabling detection
  before impact

#### Scenario: Reconvergent join is order-invariant

- **GIVEN** a kill-chain graph where the same incident hypothesis reaches a node by two paths
- **WHEN** the reconvergent branches are combined at that node
- **THEN** the result SHALL be the idempotent LUB (`join`) and SHALL be independent of branch evaluation
  order
- **AND** evidence reaching the node by both paths SHALL NOT be double-counted into the confidence

### Requirement: V1 Security Causaloid Catalog

The engine SHALL provide the V1 cross-domain security causaloid catalog, each causaloid a fusion node
building on today's schema (subject to §2 collector provisioning): S1 C2 beaconing (stage C2 / ATT&CK
T1071, T1568) fusing DNS(DGA), flow(periodicity), threat-intel, and host(Falco); S2 data exfiltration
(stage Exfil / T1041, T1567) fusing flow(large egress) with an S1 prior; S4 exposed CVE under live
exploitation (stage Exec / T1190) fusing the EXISTING KEV ranking (`endpoint_vulnerability_matches`) with
scan(exposure) and host(runtime); S5 route diversion / MITM (stage C2/Collection / T1557) fusing
BGP(anomaly), flow(unexpected AS), and MTR(path change); and S6 recon/scanning precursor (stage Recon /
T1595) fusing scan_activity with topology exposure. Each causaloid MUST tag its evidence with the
corresponding ATT&CK technique (`EvidenceRef.attck`). S3 (lateral movement) and S7 (credential attack)
SHALL NOT be authored in V1.

#### Scenario: S1 fuses four domains into one verdict

- **GIVEN** a DNS-DGA observation, a flow-periodicity observation, a threat-intel match, and a Falco host
  observation for the same correlated session
- **WHEN** the S1 C2-beaconing causaloid evaluates them
- **THEN** it SHALL fuse the four domains into a single `SecVerdict` at stage C2 tagged with ATT&CK
  techniques T1071 and T1568

#### Scenario: S4 increments KEV ranking with scan and host fusion

- **GIVEN** a host whose CVE is already ranked as exploitable by the existing KEV ranking in
  `endpoint_vulnerability_matches`, plus a scan-exposure observation and a host-runtime observation
- **WHEN** the S4 causaloid evaluates them
- **THEN** it SHALL emit a verdict at stage Exec / T1190 whose new value is the scan∧host fusion (the KEV
  prioritization is reused, not re-derived)

#### Scenario: S3 and S7 are not authored in V1

- **WHEN** the V1 catalog is enumerated
- **THEN** it SHALL contain S1, S2, S4, S5, and S6
- **AND** it SHALL NOT contain S3 or S7 (blocked on host-auth ingest)

### Requirement: Detect-Respond via CSM

Detection SHALL wire the SPRT-tested verdict into a DeepCausality `CSM` composed of a `CausalState` and a
`CausalAction`. Because `CausalAction::new` takes a bare `fn() -> Result<(), ActionError>` pointer that
cannot capture, the entity and verdict SHALL be threaded through the `CausalState` and a static
registry/queue keyed by entity id, read by a NON-capturing `fn` — a capturing closure MUST NOT be used.
The action SHALL be triggered by `is_active()` (SPRT over the reconstructed `Uncertain<f64>`), and V1
SHALL dispatch `alert_only` (auto-mitigation actuation is deferred to `add-causal-mitigation`).

#### Scenario: is_active (SPRT) triggers a non-capturing action

- **GIVEN** a `CSM` built from `CausalState::new(entity_id, …)` and `CausalAction::new(fn, …)` with the
  pending verdict placed in the registry keyed by that entity id
- **WHEN** `is_active()` (SPRT) evaluates to true for the state
- **THEN** the non-capturing `fn` action SHALL fire and read the pending verdict for the current state
  from the registry
- **AND** the action SHALL NOT rely on a capturing closure to obtain the entity or verdict

#### Scenario: V1 action is alert-only

- **WHEN** the CSM action fires in V1
- **THEN** it SHALL dispatch an `alert_only` outcome
- **AND** it SHALL NOT invoke block-flow / revoke-session / quarantine actuation (deferred to
  `add-causal-mitigation`)

### Requirement: Prediction Emission and Automation Loop

Verdicts SHALL be published by a greenfield producer on
`signals.analytics.predictions.{device_uid|incident_id}` (subject via
`ServiceRadar.Observability.CausalPredictionSubject`, `@subject_root "signals.analytics.predictions"`)
with DETERMINISTIC prediction IDs derived from stable inputs and canonical `sr:`-prefixed entity IDs. The
producer MUST NOT use the legacy `signals.causal.*` subjects. Published verdicts SHALL be routed by the
existing `AnalyticsSignals` processor (`event_writer/processors/analytics_signals.ex`) + `pipeline.ex`
into `ocsf_events`, from which they SHALL re-enter `StatefulAlertEngine.evaluate_events/1` as
`device.uid`-grouped alerts (OCSF `class_uid` 1008) AND drive the God-View render — with no new inbound
plumbing. This delta SHALL author at least one `stateful_alert_rule` with `group_by ["device.uid"]`
targeting causal-prediction events, and the engine MUST NOT bypass the alert engine by writing directly to
`monitoring.alerts`.

#### Scenario: A published prediction becomes an alert without new inbound plumbing

- **GIVEN** a `stateful_alert_rule` with `group_by ["device.uid"]` targeting causal-prediction events
- **WHEN** the producer publishes a device-scoped verdict on `signals.analytics.predictions.{device_uid}`
- **THEN** `AnalyticsSignals` + `pipeline.ex` SHALL normalize it into `ocsf_events` using the existing
  inbound path (no new inbound plumbing)
- **AND** `StatefulAlertEngine.evaluate_events/1` SHALL raise a `device.uid`-grouped alert
  (OCSF `class_uid` 1008) without the engine writing directly to `monitoring.alerts`

#### Scenario: Deterministic prediction ID is idempotent across ticks

- **GIVEN** two reasoning ticks over identical stable inputs for the same subject and causaloid
- **WHEN** the producer derives the prediction ID for each verdict
- **THEN** both ticks SHALL produce the identical prediction ID
- **AND** re-emitting a verdict with an unchanged prediction ID SHALL NOT create a duplicate event, alert,
  or render node

#### Scenario: Verdict drives the God-View render

- **WHEN** a normalized verdict is consumed by the God-View render path
- **THEN** it SHALL map deterministically to exactly one of `root_cause | affected | healthy | unknown`
  without altering the existing snapshot contract
- **AND** a verdict on a device id summarized into an endpoint-cluster summary node SHALL still classify
  (mapping to the cluster summary node or falling to `unknown`) rather than silently failing to render
