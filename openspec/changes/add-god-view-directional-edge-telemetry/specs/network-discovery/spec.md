## ADDED Requirements
### Requirement: Directional topology edge telemetry preservation
The system SHALL preserve directional traffic telemetry for canonical topology edges by carrying A→B and B→A packet/bit rates through enrichment and snapshot export.

#### Scenario: Both-sided interface telemetry available
- **GIVEN** a canonical topology edge where interface telemetry is available for both endpoint sides
- **WHEN** topology edge telemetry is enriched for God-View
- **THEN** the edge SHALL include directional fields for both A→B and B→A rates
- **AND** aggregate edge telemetry fields SHALL remain available for compatibility

#### Scenario: One-sided interface telemetry available
- **GIVEN** a canonical topology edge where telemetry is available for only one endpoint side
- **WHEN** telemetry is enriched
- **THEN** the available directional side SHALL be populated
- **AND** the missing side SHALL be explicitly empty/zero according to the edge telemetry contract
- **AND** enrichment SHALL NOT synthesize the missing direction from aggregate values

#### Scenario: Canonical dedupe retains directional telemetry
- **GIVEN** multiple mapper topology rows that collapse into one canonical edge
- **WHEN** deduplication and enrichment run
- **THEN** the resulting canonical edge SHALL retain directional rates for both sides when available
- **AND** directional telemetry SHALL NOT be dropped solely because the edge structure is undirected
