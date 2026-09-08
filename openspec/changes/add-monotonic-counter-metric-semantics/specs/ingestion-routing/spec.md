## ADDED Requirements

### Requirement: Raw Counter Preservation
The metric ingestion path SHALL preserve raw cumulative counter values, counter kind, temporality, monotonicity, reset anchors, and counter width where known.

#### Scenario: Cumulative counter stored with reset anchor
- **WHEN** a cumulative monotonic metric point is ingested
- **THEN** storage SHALL retain the raw counter value and reset anchor
- **AND** downstream consumers SHALL be able to recompute rates from stored data

### Requirement: Counter Idempotency and Precision
The metric ingestion path SHALL avoid precision loss and double-counting for cumulative counters.

#### Scenario: Counter64 value exceeds float exactness
- **WHEN** a Counter64 value exceeds the exact integer range of float64
- **THEN** ingestion SHALL preserve the value in integer or numeric form
- **AND** rate computation SHALL not depend on rounded float64 cumulative values

### Requirement: Metric Kind Validation
The metric ingestion path SHALL require producers to declare metric kind and compatible temporality fields for canonical metric envelopes and SHALL NOT silently coerce missing or unknown metric kind/type values to gauges.

#### Scenario: Missing metric kind is rejected
- **GIVEN** a canonical `serviceradar.metric.v1` envelope with a point value but no `kind` or `metric_type`
- **WHEN** the metric processor validates the envelope
- **THEN** ingestion SHALL reject the payload with a bounded validation error
- **AND** the processor SHALL NOT store the point as a gauge by default

#### Scenario: Sum metric declares temporality
- **GIVEN** a canonical `serviceradar.metric.v1` envelope with `kind` `sum`
- **WHEN** the metric processor validates the envelope
- **THEN** the envelope SHALL include valid `temporality`
- **AND** cumulative monotonic sums SHALL include `is_monotonic` and a reset anchor when the producer can observe one
