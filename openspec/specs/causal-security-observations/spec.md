# causal-security-observations Specification

## Purpose
TBD - created by archiving change add-causal-security-foundation. Update Purpose after archive.
## Requirements
### Requirement: Stable Observation Model

Layer 1 (data integration) SHALL expose a stable `Observation` model —
`{ entity: EntityKey (canonical sr:-prefixed id), domain: Domain, confidence:
ConfidenceSummary { mean, variance }, features: DomainFeatures, ocsf_event_id:
Uuid, observed_at: Timestamp }` — behind an `ObservationSource` trait, so that no
SRQL, NATS, or CNPG types leak into the reasoning layer. The `confidence` SHALL be
the deterministic `ConfidenceSummary` (not a live `Uncertain`), so no sampling
occurs at ingestion. The reasoning layer SHALL consume only `Observation` values
and SHALL depend only on the `ObservationSource` trait, never on the concrete
ingestion backend.

#### Scenario: Reasoning consumes Observations without knowing CNPG/NATS

- **WHEN** the reasoning layer processes signals from any data source
- **THEN** it SHALL receive `Observation` values through the `ObservationSource`
  trait
- **AND** it SHALL NOT reference any SRQL, NATS, or CNPG type, so that swapping
  the ingestion backend requires no change to reasoning

### Requirement: Central Per-Domain Confidence Construction

Layer 1 SHALL construct each `Observation.confidence: ConfidenceSummary` centrally
from the edge signal PLUS a calibration source, rather than passing an
edge-provided value through, because the edge (`rust/anomaly-core`) emits a robust
median/MAD z-score (`ReasonVerdict.score`, range `[0,∞)`, no probability/variance)
and covers only host/device metric-series. Construction SHALL use a **per-domain
static calibration config table** with two families: (a) for continuous domains
(metric-series, DNS name entropy, flow beacon periodicity, auth/scan rates, BGP
churn) a monotone logistic `mean = σ(k·(z − z0))` anchored so that it reuses the
deployed 4.0/8.0 z-score severity cutpoints (matching the shipped anomaly severity
bands, keeping numeric parity), and (b) for near-binary domains (IOC exact/CIDR
match, BGP new-origin/sub-prefix, auth first-seen) a direct high-mean/low-variance
mapping on a hit (a z-score is meaningless for a Bernoulli signal), with a miss
producing no `Observation`. The `variance` SHALL widen on low information
(`!anomalous`/pending, `baseline_count` below the minimum-samples threshold, or a
zero-dispersion magnitude-fallback score). The calibration table SHALL be
configuration that `add-causal-detection-feedback` later re-fits from analyst
labels.

#### Scenario: A metric-series edge z-score is mapped to a ConfidenceSummary

- **WHEN** a metric-series signal from the edge arrives carrying a robust z-score
  and an OCSF severity but no `Uncertain`
- **THEN** Layer 1 SHALL construct `Observation.confidence` as a
  `ConfidenceSummary { mean, variance }` by mapping the z-score through the
  continuous-domain logistic calibration (anchored at the 4.0/8.0 cutpoints)
- **AND** the resulting `Observation` SHALL carry that constructed summary, not a
  pass-through edge score

#### Scenario: A near-binary IOC match maps to high mean, low variance

- **WHEN** a threat-intel IOC exact or CIDR match is observed for an entity
- **THEN** Layer 1 SHALL construct `Observation.confidence` with a high `mean` and
  low `variance` via the near-binary calibration family, NOT via a z-score
- **AND** a non-match SHALL produce no `Observation`

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

