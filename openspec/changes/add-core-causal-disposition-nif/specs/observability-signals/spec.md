## ADDED Requirements

### Requirement: NIF-backed central seasonal disposition feeds the signal path
The system SHALL run a central seasonal disposition tier whose statistics are computed
in the disposition NIF (re-targeting the previously planned Elixir+SQL seasonal tier),
and SHALL emit its verdicts onto the existing observability signal path with a
`verdict_source` of `central-seasonal`, carrying the series key and the evaluated time
window so they can be joined with edge spike verdicts. The 168-bucket hour-of-week
profile aggregation SHALL remain a SQL/SRQL aggregate; only the scoring moves to the NIF.

#### Scenario: Central seasonal verdict is attributable and joinable
- **WHEN** the seasonal disposition worker scores the latest bucket for a series and the NIF returns a breach
- **THEN** the worker SHALL emit a verdict onto the signal path with `verdict_source = central-seasonal`
- **AND** the verdict SHALL carry the series key and time window required to join it with edge spike verdicts

#### Scenario: Busy time-of-day is not flagged
- **GIVEN** a series whose value is high every weekday at 9am but the current value is within its hour-of-week baseline distribution
- **WHEN** the NIF scores the latest bucket
- **THEN** it SHALL NOT emit a breach verdict for that bucket

#### Scenario: Off-baseline-for-time is flagged
- **GIVEN** a series whose value at an hour-of-week is far outside that bucket's historical distribution (for example a weekday-9am level at Sunday 3am)
- **WHEN** the NIF scores the latest bucket
- **THEN** it SHALL emit an off-baseline-for-time breach verdict attributable to the central seasonal source

### Requirement: Edge spike and central seasonal verdicts are correlated
The system SHALL correlate edge spike verdicts (`verdict_source = edge-spike`) with
central seasonal verdicts (`verdict_source = central-seasonal`) by series and overlapping
time window, and SHALL combine them so a single real event yields one enriched alert: a
spike explained by seasonality SHALL be suppressed or downgraded; a spike that is also
off-baseline for the time SHALL be escalated; a seasonal deviation with no edge spike
SHALL still be surfaced; and a spike for which the seasonal tier reports an insufficient
baseline SHALL pass through unmodified.

#### Scenario: Seasonal-expected spike is suppressed
- **GIVEN** an edge spike verdict for a series
- **AND** the central seasonal disposition says the current value is normal for this time-of-day/day-of-week
- **WHEN** the verdicts are correlated
- **THEN** the spike SHALL be suppressed or downgraded rather than alerted as an anomaly

#### Scenario: Spike that is also off-baseline is escalated
- **GIVEN** an edge spike verdict for a series
- **AND** the central seasonal disposition says the current value is also off-baseline for this time
- **WHEN** the verdicts are correlated
- **THEN** the system SHALL escalate it as a high-confidence anomaly

#### Scenario: Seasonal-only deviation is surfaced
- **GIVEN** no edge spike verdict for a series
- **AND** the central seasonal disposition says the series is off-baseline for this time
- **WHEN** the verdicts are correlated
- **THEN** the system SHALL surface a seasonal anomaly

#### Scenario: Insufficient-baseline spike passes through
- **GIVEN** an edge spike verdict for a series
- **AND** the central seasonal disposition reports an insufficient seasonal baseline for that bucket
- **WHEN** the verdicts are correlated
- **THEN** the spike SHALL pass through unmodified, with the edge signal as the only detection

### Requirement: Disposition output is composed into causal reasoning as evidence
Central disposition verdicts (anomaly and capacity-forecast) SHALL be emitted on the
`signals.causal.predictions.*` envelope seam and consumed by the standalone causal engine
as causal evidence, rather than the disposition kernel being merged into the causal engine.
The disposition NIF (per-series streaming substrate) and the causal engine (cross-entity
graph reasoning) SHALL remain separate components joined only by this envelope contract.

#### Scenario: Capacity forecast becomes causal evidence
- **WHEN** the capacity worker emits a `capacity_forecast` prediction envelope on `signals.causal.predictions.*`
- **THEN** the causal engine SHALL ingest it as causal evidence
- **AND** the disposition kernel SHALL NOT be embedded inside the causal engine
