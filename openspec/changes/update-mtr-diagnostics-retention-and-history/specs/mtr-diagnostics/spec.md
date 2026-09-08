## ADDED Requirements

### Requirement: Native MTR Visual Diagnostics
The web UI SHALL provide first-party MTR visual diagnostics that answer common path-history questions without requiring export to Grafana or another dashboarding tool.

#### Scenario: Operator reviews target path health over retained history
- **GIVEN** retained MTR traces exist for a target
- **WHEN** an operator opens the MTR diagnostics page for that target
- **THEN** the UI shows latency, loss, reachability, and hop-count trends across the selected time range
- **AND** each summary can drill down to the underlying trace and hop rows

#### Scenario: Operator investigates path changes
- **GIVEN** retained MTR traces for a target contain different hop sequences over time
- **WHEN** the operator opens path-change analysis
- **THEN** the UI identifies when the path changed
- **AND** it highlights added, removed, and changed hops with trace timestamps

#### Scenario: Operator compares source-agent vantage points
- **GIVEN** multiple source agents have retained traces for the same target
- **WHEN** the operator groups MTR diagnostics by source agent
- **THEN** the UI shows per-agent reachability, latency, loss, and path differences
- **AND** it makes vantage-specific failures distinguishable from broad target failures

### Requirement: MTR Retention Visibility
The web UI SHALL show the configured MTR retention window and current retention policy status wherever retained MTR history is browsed or configured.

#### Scenario: Operator views retained history coverage
- **GIVEN** MTR retention is configured and MTR traces exist for a target
- **WHEN** an operator opens the MTR diagnostics page or a device MTR tab
- **THEN** the UI shows the configured retention window
- **AND** it indicates the earliest and latest retained trace times for the current filter

#### Scenario: Poll cadence estimates retained samples
- **GIVEN** an MTR policy has a known polling cadence
- **WHEN** the UI displays retention coverage for that policy or target
- **THEN** it estimates how many polls are retained per target for the configured retention period

## MODIFIED Requirements

### Requirement: MTR Results Page
The web UI SHALL provide a dedicated MTR diagnostics page listing retained traces with paginated browsing, drill-down to hop-by-hop detail, path comparison, native visual diagnostics, and on-demand trace execution.

#### Scenario: Retained traces list is paginated
- **WHEN** the operator navigates to the MTR diagnostics page
- **THEN** a paginated table of retained MTR traces is displayed with target, source agent, hop count, reachability, and timestamp
- **AND** traces are filterable by target, agent, protocol, reachability, and time range
- **AND** the table can browse beyond the first recent page until all matching retained traces have been exhausted

#### Scenario: Trace detail drill-down
- **WHEN** the operator selects a trace from the list
- **THEN** a hop-by-hop table is displayed with: hop number, IP, hostname, ASN/org, loss%, avg/min/max RTT, jitter, MPLS labels
- **AND** per-hop latency sparklines show recent trend when enough retained history exists

#### Scenario: Path comparison
- **WHEN** the operator selects two traces to the same target
- **THEN** changed hops are highlighted (IP changes, new hops, missing hops)
- **AND** latency differences per hop are shown

#### Scenario: Native visual summaries remain evidence-backed
- **GIVEN** the MTR diagnostics page renders trend, heatmap, reachability, or path-change visuals
- **WHEN** the operator selects a visual segment, point, bucket, or row
- **THEN** the UI exposes the trace and hop evidence behind that visual

### Requirement: Device Detail MTR Tab
The web UI SHALL include an MTR tab on the device detail page showing retained traces involving the device, paginated history controls, compact visual summaries, and a quick action to run an on-demand trace.

#### Scenario: Device MTR retained history
- **WHEN** the operator views the MTR tab on a device detail page
- **THEN** traces where the device IP appears as source, target, or intermediate hop are listed from retained history
- **AND** historical path, reachability, loss, and latency trends are charted over the selected time range
- **AND** the operator can page through all retained matching traces rather than only seeing a fixed recent slice

#### Scenario: On-demand trace from device page
- **WHEN** the operator clicks "Run MTR" on a device detail page
- **THEN** a modal appears to select source agent and protocol
- **AND** submitting triggers an `mtr.run` command via ControlStream
- **AND** results are displayed inline when the trace completes

#### Scenario: Device MTR tab explains limited history
- **GIVEN** fewer MTR traces are retained than the selected time range would imply
- **WHEN** the device MTR tab renders
- **THEN** the UI indicates whether the limit is due to retention, polling cadence, or no matching traces
