# srql

## ADDED Requirements

### Requirement: Per-series rates may be summed rather than averaged

SRQL SHALL accept `agg:rate_sum` on a `bucket:` query wherever `agg:rate` is
accepted. It SHALL compute per-series rates exactly as `agg:rate` does, and
SHALL combine them within each display bucket by summation rather than by mean.

The delta computation SHALL remain partitioned by the full series identity for
both aggregations, so each rate is derived from a single underlying counter.

Counter resets SHALL continue to yield NULL and be excluded from the combine for
both aggregations.

`agg:rate` SHALL be unchanged.

#### Scenario: A fleet total across per-controller counters
- **GIVEN** a counter kept independently by several controllers for the same RADIUS server
- **WHEN** a client sends `... bucket:30m agg:rate_sum series:tags.radius_server`
- **THEN** each bucket holds the summed rate across those controllers
- **AND** the generated SQL combines with `SUM(rate_value)`

#### Scenario: agg:rate keeps averaging
- **WHEN** a client sends the same query with `agg:rate`
- **THEN** the generated SQL still combines with `AVG(rate_value)`

#### Scenario: Deltas stay per underlying counter
- **WHEN** a client uses `agg:rate_sum`
- **THEN** the LAG window is still partitioned by the full series identity
- **AND** rates are never derived across two different counters

#### Scenario: Counter resets are still skipped
- **WHEN** a counter wraps or resets
- **THEN** that interval contributes no value to the sum
- **AND** the wrap does not surface as a spike

#### Scenario: The unknown-aggregation error names it
- **WHEN** a client sends an unrecognised `agg:`
- **THEN** the error lists `rate_sum` among the supported values
