## ADDED Requirements

### Requirement: Flow Traffic Continuous Aggregates
The database SHALL maintain TimescaleDB continuous aggregates over `platform.ocsf_network_activity` at three resolutions: 5-minute, 1-hour, and 1-day. Each CAGG SHALL pre-aggregate bytes, packets, and flow count grouped by source IP, destination IP, protocol, destination port, application label, sampler address, and direction.

#### Scenario: 5-minute CAGG refreshes automatically
- **GIVEN** the `platform.flow_traffic_5min` continuous aggregate exists
- **WHEN** new flow records are inserted into `platform.ocsf_network_activity`
- **THEN** the 5-minute CAGG refreshes within 5 minutes via its configured refresh policy
- **AND** querying the CAGG for a recent 5-minute bucket returns aggregated totals

#### Scenario: Hierarchical CAGG chain
- **GIVEN** the 1-hour CAGG `platform.flow_traffic_1h` is defined over the 5-minute CAGG
- **WHEN** the 5-minute CAGG has data for a complete hour
- **THEN** the 1-hour CAGG aggregates from the 5-minute data (not raw)
- **AND** the 1-day CAGG `platform.flow_traffic_1d` aggregates from the 1-hour CAGG

#### Scenario: Query-time auto-resolution selects appropriate CAGG
- **GIVEN** a SRQL query with a 7-day time window
- **WHEN** the SRQL engine resolves the query source
- **THEN** it selects the 1-hour CAGG (`platform.flow_traffic_1h`) instead of raw data
- **AND** the query completes significantly faster than querying raw data for the same window

### Requirement: 95th Percentile Bandwidth Calculation
The database SHALL support 95th percentile bandwidth calculation over the continuous aggregates. This MUST be available as a query-time operation using TimescaleDB `percentile_agg` or equivalent.

#### Scenario: Monthly 95th percentile per interface
- **GIVEN** 30 days of 5-minute CAGG data for sampler `10.0.0.1`
- **WHEN** a 95th percentile query is executed for that sampler
- **THEN** the result represents the bandwidth value below which 95% of all 5-minute samples fall
- **AND** this matches the industry-standard burstable billing calculation
