# camera-streaming — deltas

## ADDED Requirements

### Requirement: Camera availability and stream operability are coherent
Camera dashboards SHALL present inventory availability and stream operability as distinct, labeled dimensions derived from their respective sources, and SHALL never present an unexplained contradiction (e.g. a camera counted "Available" while its tile reports "Agent offline") — a camera that is inventory-available but not stream-operable SHALL show a combined state with the blocking reason.

#### Scenario: Available but not streamable is explained
- **GIVEN** a camera whose `availability_status` is available
- **AND** whose relay preview cannot open because the assigned agent is offline
- **WHEN** the camera panel renders
- **THEN** the camera SHALL be shown as available-but-not-streamable with the reason ("agent offline")
- **AND** the summary counts SHALL not present the camera as operational without qualification

#### Scenario: Fully operational camera
- **GIVEN** a camera that is inventory-available and has a working relay path
- **WHEN** the camera panel renders
- **THEN** the camera SHALL be shown as available with no degraded-state qualifier
