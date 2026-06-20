## ADDED Requirements

### Requirement: Timeseries Top-N Other Rollup
The SRQL service SHALL support `other:true` for additive grouped `timeseries_metrics`, `snmp`, and `rperf` stats queries.

#### Scenario: Fold timeseries tail groups into Other
- **GIVEN** a timeseries stats query groups by a supported timeseries column
- **AND** the query uses additive `sum(value)` or `count(*)` aggregations
- **AND** the query includes `sort:<metric>:desc`, `limit:N`, and `other:true`
- **WHEN** the number of groups exceeds the limit
- **THEN** SRQL returns the top N groups in sorted order
- **AND** SRQL returns one final row with grouped columns set to null
- **AND** the final row includes `__other__: true` and additive sums for the tail groups

#### Scenario: Reject non-additive Other rollup
- **GIVEN** a grouped timeseries stats query uses `avg(value)`
- **WHEN** the query includes `other:true`
- **THEN** SRQL rejects the query because averaging already-aggregated tail groups would be incorrect
