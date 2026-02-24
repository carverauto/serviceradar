## ADDED Requirements
### Requirement: God-View directional flow rendering uses real telemetry only
God-View SHALL render bidirectional edge particles only from real directional edge telemetry fields and SHALL NOT synthesize reverse-direction flow from aggregate edge metrics.

#### Scenario: Directional telemetry for both sides
- **GIVEN** a topology edge payload with A→B and B→A directional rates
- **WHEN** God-View renders atmosphere packet flow
- **THEN** the renderer SHALL draw both directional streams using those real directional values

#### Scenario: Directional telemetry on one side only
- **GIVEN** a topology edge payload with only one directional side populated
- **WHEN** God-View renders atmosphere packet flow
- **THEN** the renderer SHALL draw only the available direction
- **AND** SHALL NOT synthesize a reverse stream from aggregate values

#### Scenario: No directional telemetry fields present
- **GIVEN** a topology edge payload that includes only aggregate flow metrics
- **WHEN** God-View renders atmosphere packet flow
- **THEN** the renderer SHALL use single-stream aggregate behavior
- **AND** SHALL NOT invent directional lanes

#### Scenario: Telemetry-ineligible topology edge
- **GIVEN** a topology edge payload marked telemetry-ineligible due to missing interface attribution or required counters
- **WHEN** God-View renders atmosphere packet flow
- **THEN** the renderer SHALL avoid showing misleading packet activity for that edge
- **AND** SHALL preserve structural edge visibility for topology context

### Requirement: God-View packet stream density and tube coverage parity
God-View SHALL render packet streams with dense tube-aligned coverage comparable to the approved deckgl PoC visual profile while preserving zoom-tier readability.

#### Scenario: Mid-zoom density and tube fill
- **GIVEN** topology edges with active telemetry at mid zoom
- **WHEN** packet layers are rendered
- **THEN** particle density SHALL fill the edge tube without appearing sparse
- **AND** particle spread SHALL remain near the visual edge tube boundary without visibly overflowing it

#### Scenario: Zoomed-out readability
- **GIVEN** the user zooms far out
- **WHEN** packet layers are rendered
- **THEN** particle visibility and spread SHALL avoid neon-line saturation artifacts
- **AND** edge structures SHALL remain legible as topology links

#### Scenario: Zoomed-in readability
- **GIVEN** the user zooms far in
- **WHEN** packet layers are rendered
- **THEN** particles SHALL remain visibly distinct and readable
- **AND** zoom scaling SHALL not reduce particles below a practical visibility floor
