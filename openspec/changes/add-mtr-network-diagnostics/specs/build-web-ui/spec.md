## ADDED Requirements

### Requirement: MTR Diagnostics Page
The web UI SHALL provide a dedicated MTR diagnostics page at `/diagnostics/mtr` listing recent traces with drill-down to hop-by-hop detail, path comparison, and on-demand trace execution.

#### Scenario: Operator views MTR diagnostics
- **WHEN** the operator navigates to `/diagnostics/mtr`
- **THEN** a table of recent MTR traces is displayed with target, source agent, hop count, reachability, and timestamp
- **AND** the operator can filter by target, agent, and time range
- **AND** selecting a trace shows hop-by-hop detail with latency, loss, ASN, MPLS labels

### Requirement: God View MTR Overlay Layer
The God View topology visualization SHALL include an MTR path overlay layer that renders MTR-discovered network paths as animated directional edges with latency and loss visual encoding.

#### Scenario: MTR overlay toggled on
- **WHEN** the operator enables the MTR overlay in God View layer controls
- **THEN** `MTR_PATH` edges from `platform_graph` are rendered as animated directional arcs
- **AND** edge color encodes latency (green → yellow → red gradient)
- **AND** edge thickness encodes loss percentage

### Requirement: Device Detail MTR Tab
The device detail page SHALL include an MTR tab showing traces involving the device and providing on-demand trace execution.

#### Scenario: Operator views device MTR history
- **WHEN** the operator opens the MTR tab on a device detail page
- **THEN** traces where the device IP is source, target, or intermediate hop are listed
- **AND** a "Run MTR" action triggers an ad-hoc trace via ControlStream
