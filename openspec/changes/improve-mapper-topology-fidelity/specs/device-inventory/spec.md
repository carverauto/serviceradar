## ADDED Requirements
### Requirement: Inventory promotion from topology endpoint sightings
The system SHALL promote downstream endpoint sightings from mapper topology evidence into inventory records (or candidate records) with confidence and freshness metadata.

#### Scenario: Endpoint observed via downstream switch evidence
- **GIVEN** mapper ingests ARP/bridge/CAM evidence for an endpoint behind a managed switch
- **WHEN** ingestion processes the observation
- **THEN** the endpoint SHALL be represented in inventory data with last-seen timestamp and confidence metadata
- **AND** source evidence SHALL reference the observing infrastructure device

#### Scenario: Repeated sightings refresh endpoint record
- **GIVEN** an endpoint discovered indirectly from topology evidence already exists in inventory
- **WHEN** the endpoint is observed again
- **THEN** last-seen metadata SHALL be refreshed
- **AND** confidence/evidence metadata SHALL be merged without duplicating the endpoint record
