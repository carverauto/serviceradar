## ADDED Requirements

### Requirement: NetFlow Protocol Activity Chart
The system SHALL provide an SRQL-driven stacked area chart showing NetFlow activity by protocol over time.

#### Scenario: Operator views protocol activity for last hour
- **WHEN** the operator opens the NetFlows view with `time:last_1h`
- **THEN** the UI shows a stacked area chart with protocol series (e.g., TCP/UDP/other)
- **AND** the chart data is loaded via SRQL queries (no Ecto queries for chart data)

### Requirement: Frequent Talkers Tables
The system SHALL provide two SRQL-driven "Frequent Talkers" tables for NetFlows: one ordered by packet count and one ordered by byte volume.

#### Scenario: Operator identifies packet-heavy sources
- **WHEN** the operator views the NetFlows dashboard
- **THEN** a "Frequent Talkers (Packet Count)" table is shown with a stable ordering
- **AND** clicking a talker applies an SRQL filter (e.g., `src_ip:<ip>` or `dst_ip:<ip>`) to the flows list

### Requirement: NetFlow Application Activity Chart
The system SHALL provide an SRQL-driven stacked area chart showing NetFlow activity by application over time.

#### Scenario: Operator sees top applications and drills down
- **WHEN** the operator opens the NetFlows view
- **THEN** the UI shows a stacked area chart whose series represent derived application labels
- **AND** a legend is shown alongside the chart mapping colors to application labels
- **AND** clicking a series applies an SRQL `app:<label>` filter to the flows list

### Requirement: Application Classification
The system SHALL derive an application label for NetFlow records using protocol/port mapping and admin-defined override rules.

#### Scenario: Baseline classification labels HTTPS flows
- **GIVEN** a flow has `protocol_num:6` (TCP) and `dst_endpoint_port:443`
- **WHEN** the flow is queried via SRQL
- **THEN** the flow’s derived application label is `https` (or a configured equivalent)

#### Scenario: Admin override rule takes precedence
- **GIVEN** an enabled override rule matches `{protocol_num:6, dst_port:443, dst_cidr:140.82.112.0/20}` with `app_label:github`
- **WHEN** the operator queries `in:flows` that includes traffic matching the rule
- **THEN** the derived application label for matching flows is `github`

