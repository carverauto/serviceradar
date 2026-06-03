# observability-signals Specification

## ADDED Requirements

### Requirement: State-Change Event Feed
The system SHALL publish application-level state-TRANSITION events for current-state tables to NATS subjects of the form `signals.state.<table>` so that the causal engine can consume live state deltas without logical replication or pgoutput CDC. The feed SHALL cover the current-state tables `ocsf_devices`, `service_status`, and `health_events` (and MAY cover additional current-state projections such as virtualization and AGE topology projection). Delivery SHALL be at-least-once, and consumers SHALL treat events as idempotent on the canonical entity identity. The feed SHALL NEVER stream TimescaleDB hypertables; hypertable state SHALL be queried on-demand via SRQL/EmbeddedSrql instead.

This is an application-emitted change feed, NOT logical replication. Events SHALL be published only when a row TRANSITIONS to a new state, not on every write, and SHALL carry the canonical `sr:`-prefixed entity identity (for example `ocsf_devices.uid`) so a consumer can reconcile against the canonical ID space without inventing a parallel one.

#### Scenario: Device state transition published to NATS
- **WHEN** an `ocsf_devices` row transitions to a new health or risk state
- **THEN** the system SHALL publish a state-change event to `signals.state.ocsf_devices`
- **AND** the event SHALL include the canonical device uid and the prior and new state values

#### Scenario: Service status transition published to NATS
- **WHEN** a `service_status` row transitions between availability states
- **THEN** the system SHALL publish a state-change event to `signals.state.service_status`
- **AND** delivery SHALL be at-least-once so a transient consumer outage does not silently drop the transition

#### Scenario: Hypertables are never streamed on the feed
- **GIVEN** a TimescaleDB hypertable such as a metrics or rule-history table receives writes
- **WHEN** those writes occur
- **THEN** the system SHALL NOT publish per-row change events for the hypertable on `signals.state.<table>`
- **AND** hypertable state SHALL be obtained on-demand via SRQL instead

#### Scenario: Consumer treats redelivery idempotently
- **GIVEN** a state-change event is redelivered under at-least-once semantics
- **WHEN** a consumer processes the duplicate
- **THEN** the consumer SHALL reconcile on the canonical entity identity without producing a divergent state

### Requirement: Causal Prediction Signal Domain
The system SHALL normalize causal prediction signals published to `signals.causal.predictions.{device_uid|incident_id}` into `ocsf_events` through the existing CausalSignals processor, so that engine verdicts re-enter the observability pipeline as first-class OCSF events. Normalized prediction events SHALL preserve a deterministic prediction identity, the canonical subject identity (`device_uid` or `incident_id`), the verdict classification, and explainability/provenance metadata. Once normalized, prediction events SHALL be eligible for stateful alert evaluation and for topology causal overlay rendering through the existing routing of the `signals.causal.*` prefix.

This domain is the verdict re-ingestion seam. No new inbound plumbing is introduced; the prediction subject is routed by the same `signals.causal.*` prefix already handled by the CausalSignals processor and pipeline batcher. See cross-referenced capability `causal-prediction-signals` for the producer contract that emits these signals.

#### Scenario: Prediction signal normalized into an OCSF event
- **GIVEN** a causal prediction is published to `signals.causal.predictions.<device_uid>`
- **WHEN** the CausalSignals processor consumes the signal
- **THEN** the system SHALL normalize it into an `ocsf_events` row
- **AND** the normalized event SHALL preserve the deterministic prediction id, the canonical device uid, the verdict classification, and explainability metadata

#### Scenario: Normalized prediction re-enters the automation loop
- **GIVEN** a normalized causal prediction event exists in `ocsf_events`
- **WHEN** stateful alert evaluation runs over OCSF events grouped by `device.uid`
- **THEN** the prediction event SHALL be eligible to create or update an alert incident
- **AND** the alert SHALL reference the triggering prediction event

#### Scenario: Deterministic prediction id is replay-safe
- **GIVEN** the same causal prediction is published more than once with the same deterministic prediction id
- **WHEN** the signals are normalized
- **THEN** the system SHALL treat them as the same prediction identity
- **AND** SHALL NOT create divergent duplicate prediction events for the unchanged verdict

### Requirement: Inventory Causal Signal Domain
The system SHALL normalize inventory causal signals published to `signals.causal.inventory.*` into `ocsf_events` through the existing CausalSignals processor. Inventory signals that represent vulnerability findings SHALL be normalized as OCSF events with `class_uid` 2004 (Vulnerability Finding) and SHALL preserve the canonical device identity and a per-device risk reference suitable for risk composition. Inventory signal normalization SHALL NOT perform package-to-CVE coordinate matching; that matching is owned by the cross-referenced capability `add-cti-signal-coverage`, and this domain SHALL only consume the resulting per-device risk via the cross-referenced capability `inventory-risk-feed`.

#### Scenario: Inventory vulnerability signal normalized as OCSF 2004
- **GIVEN** an inventory causal signal representing a per-device vulnerability finding is published to `signals.causal.inventory.vulnerability`
- **WHEN** the CausalSignals processor consumes the signal
- **THEN** the system SHALL normalize it into an `ocsf_events` row with `class_uid` 2004
- **AND** the event SHALL preserve the canonical device uid and the per-device risk reference

#### Scenario: Inventory signal does not author coordinate matching
- **GIVEN** an inventory causal signal carries package coordinate context
- **WHEN** the signal is normalized
- **THEN** the system SHALL NOT perform package-to-CVE coordinate matching during normalization
- **AND** SHALL rely on the per-device risk contribution supplied by the inventory risk feed

#### Scenario: Inventory finding feeds risk-aware causal evaluation
- **GIVEN** a normalized inventory vulnerability event references a device with an elevated per-device risk score
- **WHEN** downstream causal evaluation consumes the device risk
- **THEN** the elevated risk SHALL be available for risk composition on that device
- **AND** the normalized event SHALL remain queryable through the normal observability surfaces

## MODIFIED Requirements

### Requirement: External Causal Signal Normalization
The system SHALL normalize causal signals into a common causal signal envelope with source provenance and replay-safe identity. This SHALL include external SIEM and BMP/BGP routing events AND the internal causal domains: causal prediction signals on `signals.causal.predictions.*` and inventory causal signals on `signals.causal.inventory.*`. All normalized causal signals SHALL carry signal type, severity, source provenance, and a replay-safe event identity, and SHALL be routed through the existing `signals.causal.*` prefix handling rather than introducing new inbound plumbing.

#### Scenario: BMP event normalized for causal evaluation
- **GIVEN** a BMP routing event is received from the external BMP collector path
- **WHEN** the event enters the observability pipeline
- **THEN** the system SHALL normalize it into the causal envelope with signal type, severity, source, and event identity fields
- **AND** the normalized event SHALL be eligible for topology causal overlay evaluation

#### Scenario: SIEM alert normalized with provenance
- **GIVEN** a SIEM alert event is received from an external source
- **WHEN** the event is normalized
- **THEN** the causal envelope SHALL include source provenance, detection timestamp, and normalized severity

#### Scenario: Internal causal domains are enumerated by the normalizer
- **GIVEN** a signal published on `signals.causal.predictions.*` or `signals.causal.inventory.*`
- **WHEN** the signal enters the observability pipeline
- **THEN** the system SHALL recognize it as a normalizable causal domain under the `signals.causal.*` prefix
- **AND** the normalized event SHALL carry replay-safe identity and source provenance consistent with the external causal domains
