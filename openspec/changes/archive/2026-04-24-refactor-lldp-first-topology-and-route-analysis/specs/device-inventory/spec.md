## ADDED Requirements
### Requirement: Endpoint Attachment Inventory Visibility
The inventory system SHALL represent downstream endpoints observed via infrastructure evidence without collapsing them into infrastructure backbone topology.

#### Scenario: Endpoint discovered behind switch/AP
- **GIVEN** endpoint attachment evidence associates a client IP/MAC to an infrastructure port or AP
- **WHEN** ingestion resolves the observation
- **THEN** the endpoint SHALL be represented in inventory with confidence and last-seen metadata
- **AND** the endpoint SHALL be linked via endpoint-attachment evidence, not as infrastructure `CONNECTS_TO`

#### Scenario: Stale endpoint attachment ages out
- **GIVEN** an endpoint attachment is no longer observed
- **WHEN** its freshness TTL expires
- **THEN** the attachment relationship SHALL be removed or marked stale
- **AND** historical evidence SHALL remain queryable for diagnostics
