# causal-security-observations Specification

## ADDED Requirements

### Requirement: Stable Observation Model

Layer 1 (data integration) SHALL expose a stable `Observation` model —
`{ entity: EntityKey (canonical sr:-prefixed id), domain: Domain, confidence:
UncertainF64, features: DomainFeatures, ocsf_event_id: Uuid, observed_at:
Timestamp }` — behind an `ObservationSource` trait, so that no SRQL, NATS, or
CNPG types leak into the reasoning layer. The reasoning layer SHALL consume only
`Observation` values and SHALL depend only on the `ObservationSource` trait, never
on the concrete ingestion backend.

#### Scenario: Reasoning consumes Observations without knowing CNPG/NATS

- **WHEN** the reasoning layer processes signals from any data source
- **THEN** it SHALL receive `Observation` values through the `ObservationSource`
  trait
- **AND** it SHALL NOT reference any SRQL, NATS, or CNPG type, so that swapping
  the ingestion backend requires no change to reasoning

### Requirement: Central Per-Domain Confidence Construction

Layer 1 SHALL construct each `Observation.confidence` centrally from the edge
signal PLUS a calibration source, rather than passing an edge-provided `Uncertain`
through, because the edge (`rust/anomaly-core`) emits a z-score/severity/episode
signal and NOT an `Uncertain`, and covers only host/device metric-series. The
construction SHALL map an edge z-score or severity into an `Uncertain(mean,
variance)` using the calibration mapping.

#### Scenario: A metric-series edge z-score is mapped to an Uncertain(mean, variance)

- **WHEN** a metric-series signal from the edge arrives carrying a z-score and an
  OCSF severity but no `Uncertain`
- **THEN** Layer 1 SHALL construct the `Observation.confidence` as an
  `Uncertain(mean, variance)` derived from the edge z-score/severity combined
  with the calibration source
- **AND** the resulting `Observation` SHALL carry that constructed
  `UncertainF64` confidence, not a pass-through edge score

### Requirement: State-Change Feed Consumption

Layer 1 SHALL consume the app-level `signals.state.<table>` transition feed
(enabling `STATE_CHANGE_EVENTS_ENABLED`) as an `ObservationSource`, and SHALL NOT
use pgoutput CDC or logical replication (rejected by the `add-causal-engine`
chassis; none exists). Each state transition on a subscribed table SHALL surface
as an `Observation` keyed to the transitioning entity's canonical `sr:`-prefixed
identity.

#### Scenario: An ocsf_devices transition arrives as an Observation

- **WHEN** the `STATE_CHANGE_EVENTS_ENABLED` feed publishes an `ocsf_devices`
  state transition on `signals.state.ocsf_devices`
- **THEN** Layer 1 SHALL consume it via the `ObservationSource` trait and surface
  it as an `Observation` for the affected device
- **AND** the `Observation.entity` SHALL be the device's canonical `sr:`-prefixed
  id, with no reliance on pgoutput CDC or logical replication
