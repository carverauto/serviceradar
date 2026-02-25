## ADDED Requirements
### Requirement: Backend-Owned Canonical Edge Telemetry
The system SHALL persist canonical edge telemetry on `CANONICAL_TOPOLOGY` relationships in AGE/backend projection so topology consumers can read a single authoritative edge shape.

#### Scenario: Canonical edges include directional telemetry fields
- **GIVEN** a canonical topology edge between two devices exists
- **WHEN** backend projection updates canonical edges
- **THEN** the edge includes directional telemetry fields `flow_pps_ab`, `flow_pps_ba`, `flow_bps_ab`, `flow_bps_ba`
- **AND** includes aggregate telemetry fields `flow_pps`, `flow_bps`, `capacity_bps`
- **AND** includes telemetry metadata `telemetry_source` and `telemetry_observed_at`

### Requirement: Canonical Telemetry Read Shape for Runtime Graph
The system SHALL return canonical edge telemetry directly from AGE/runtime graph reads without requiring web-layer telemetry computation.

#### Scenario: Runtime graph query returns pre-enriched telemetry
- **GIVEN** canonical topology projection has populated edge telemetry
- **WHEN** runtime graph links are queried for GodView
- **THEN** returned rows include canonical topology identity and telemetry fields in the same payload
- **AND** web-ng does not need to query raw interface metrics to compute edge flow values
