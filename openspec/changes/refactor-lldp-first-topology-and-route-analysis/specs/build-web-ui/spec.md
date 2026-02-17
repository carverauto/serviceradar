## ADDED Requirements
### Requirement: Topology Layer Filtering Controls
The topology UI SHALL provide explicit layer controls for `backbone`, `inferred`, and `endpoint-attachment` relationships.

#### Scenario: Backbone-only topology view
- **GIVEN** a user opens the topology graph
- **WHEN** endpoint and inferred layers are disabled
- **THEN** only backbone infrastructure links SHALL be rendered

#### Scenario: Endpoint-inclusive topology view
- **GIVEN** a user enables endpoint attachments
- **WHEN** the graph refreshes
- **THEN** client/endpoint nodes and attachment links SHALL be rendered separately from backbone links

### Requirement: Route Analyzer Experience
The UI SHALL provide a route analyzer that computes and displays path outcomes for a selected source device and destination IP.

#### Scenario: Successful recursive route analysis
- **GIVEN** route snapshots exist for the selected source and intermediate devices
- **WHEN** the user runs route analysis to a destination IP
- **THEN** the UI SHALL display hop-by-hop path results using longest-prefix-match logic
- **AND** include ECMP branches where present

#### Scenario: Loop or blackhole route outcome
- **GIVEN** route data causes a loop or no valid next-hop
- **WHEN** the user runs route analysis
- **THEN** the UI SHALL indicate `loop` or `blackhole` status
- **AND** display the step where the condition was detected
