## ADDED Requirements
### Requirement: Dual-path BMP signal storage
The system SHALL persist BMP routing telemetry using a dual-path model where raw/high-volume routing updates are stored in `platform.bmp_routing_events` and only promoted/high-signal BMP events are stored in `platform.ocsf_events`.

#### Scenario: Raw route updates persist in BMP routing table
- **GIVEN** BMP route update messages are ingested from arancini subjects
- **WHEN** the EventWriter causal processor handles the batch
- **THEN** the system SHALL insert normalized routing rows into `platform.bmp_routing_events`
- **AND** those rows SHALL remain queryable for replay and topology analysis

#### Scenario: Low-signal BMP updates do not flood OCSF events
- **GIVEN** a burst of BMP route update messages that do not match promotion criteria
- **WHEN** the batch is processed
- **THEN** the system SHALL NOT insert all burst messages into `platform.ocsf_events`
- **AND** `platform.ocsf_events` SHALL remain reserved for curated/high-signal BMP events

### Requirement: BMP observability UI surface for raw routing telemetry
The web UI SHALL provide a BMP-focused observability experience for inspecting raw routing telemetry independently from generic events pages.

#### Scenario: Operator investigates routing churn without using Events page
- **GIVEN** a user opens the BMP observability view
- **WHEN** they filter by router, peer, prefix, and time window
- **THEN** the UI SHALL query raw BMP routing data
- **AND** the UI SHALL present routing-centric fields without requiring OCSF-only event semantics

### Requirement: BMP-to-OCSF correlation contract
The system SHALL preserve stable correlation identifiers and routing/topology keys between raw BMP rows and promoted OCSF BMP events.

#### Scenario: Promoted BMP incident links back to raw routing records
- **GIVEN** a promoted BMP event exists in `platform.ocsf_events`
- **WHEN** an operator drills into correlation data
- **THEN** they SHALL be able to identify corresponding raw BMP routing records
- **AND** correlation SHALL use stable event identity and routing/topology keys
