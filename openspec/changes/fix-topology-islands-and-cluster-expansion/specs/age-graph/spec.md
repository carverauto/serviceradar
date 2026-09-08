## MODIFIED Requirements

### Requirement: AGE-authoritative topology read model
The system SHALL treat canonical Apache AGE topology edges as the authoritative source for topology rendering and downstream graph consumers.

The SQL read-model projection SHALL be complete relative to canonical AGE adjacency: every device that participates in any canonical topology edge SHALL appear connected in the projected read model. Device-to-Device `ATTACHED_TO` edges with `evidence_class = 'inferred-segment'` SHALL be projected as attachment-plane rows and SHALL NOT be dropped by backbone-only relation filters.

#### Scenario: Renderer consumes canonical AGE edges
- **GIVEN** canonical topology edges are projected in AGE
- **WHEN** web topology views are generated
- **THEN** edge construction SHALL use canonical AGE adjacency
- **AND** rendering SHALL NOT require additional identity-fusion heuristics in the UI layer

#### Scenario: Inferred-segment attachment keeps device connected
- **GIVEN** a device's only canonical edge is a Device-to-Device `ATTACHED_TO` edge with `evidence_class = 'inferred-segment'`
- **WHEN** the SQL read-model projection refreshes from AGE
- **THEN** the projection SHALL include a row connecting that device to its attachment neighbor
- **AND** the God-View attachment census or bounded drill-down SHALL preserve a recoverable connection to its anchor instead of representing it as an island
- **AND** this completeness SHALL NOT require every attachment device to render simultaneously as a default backbone peer

#### Scenario: Projection completeness matches canonical adjacency
- **GIVEN** the canonical AGE graph contains N distinct devices participating in Device-to-Device canonical edges
- **WHEN** the read-model projection refresh completes
- **THEN** the union of local and neighbor device ids across projected rows SHALL equal those N devices
