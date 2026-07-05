# srql (delta)

## ADDED Requirements

### Requirement: Rate aggregation output is a rate and is computed per polling series

`agg:rate` SHALL return per-bucket rates derived from counter deltas computed within a single polling series (partitioning consecutive-sample deltas by the polling series/agent, not by metric name alone, so interleaved polls of one target by multiple agents never produce cross-agent deltas). Counter-wrap correction SHALL be bounded by a plausibility ceiling rather than applied unconditionally. Consumers of `agg:rate` results MUST treat values as rates; re-applying counter-to-rate conversion downstream is a contract violation.

#### Scenario: Multi-agent polling of one target does not corrupt rates
- **GIVEN** one device interface polled by five agents on interleaved schedules
- **WHEN** `agg:rate` aggregates its counter series
- **THEN** deltas are computed within each polling series and combined per bucket
- **AND** no cross-agent delta reaches the wrap-correction branch

#### Scenario: Implausible wrap deltas are rejected
- **GIVEN** a small negative delta caused by clock skew between samples
- **WHEN** the wrap branch would add 2^64 to the delta
- **THEN** the delta is discarded as implausible instead of producing an astronomical rate

#### Scenario: Downstream consumers do not re-convert
- **GIVEN** a chart panel whose query uses `agg:rate`
- **WHEN** the panel renders the response
- **THEN** it renders the values as rates directly
- **AND** counter-to-rate conversion modes are reserved for raw cumulative-counter queries
