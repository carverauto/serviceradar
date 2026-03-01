## ADDED Requirements

### Requirement: Flow entity supports aggregation queries for widgets
The SRQL service SHALL support aggregation queries for `in:flows` that power NetFlow dashboard widgets (top talkers, top ports, and protocol summaries) without requiring clients to fetch and aggregate raw rows.

#### Scenario: Top talkers by bytes
- **GIVEN** flows exist in the selected time window
- **WHEN** a client queries `in:flows time:last_5m stats:sum(bytes) as bytes by src_ip`
- **THEN** SRQL returns a list of `{src_ip, bytes}` objects ordered by bytes descending

#### Scenario: Top ports by bytes
- **GIVEN** flows exist in the selected time window
- **WHEN** a client queries `in:flows time:last_5m stats:sum(bytes) as bytes by dst_port`
- **THEN** SRQL returns a list of `{dst_port, bytes}` objects ordered by bytes descending

### Requirement: Flow time-series bucketing for charts
The SRQL service SHALL support time-bucketing aggregations for `in:flows` suitable for charting traffic volume over time.

#### Scenario: Traffic series by 5-minute bucket
- **GIVEN** flows exist over the last hour
- **WHEN** a client queries `in:flows time:last_1h stats:sum(bytes) as bytes by time_bucket:5m`
- **THEN** SRQL returns bucketed results ordered by bucket ascending
- **AND** buckets with no data are returned as zero when the query requests gap filling

### Requirement: Flow query filters for dashboard drill-down
The SRQL service SHALL support filter tokens commonly used for NetFlow dashboard drill-down, including protocol, src/dst IP, ports, ASN, directionality, and CIDR matching where applicable.

#### Scenario: Drill-down to a single talker and protocol
- **WHEN** a client queries `in:flows src_ip:10.0.0.10 protocol:tcp time:last_15m`
- **THEN** SRQL returns only flows matching that talker and protocol within the window
