## ADDED Requirements
### Requirement: Canonical endpoint attachments are queryable for topology rendering
The system SHALL project discovered client or endpoint devices into the canonical AGE topology read model as endpoint attachment relations separate from backbone infrastructure adjacency.

#### Scenario: Endpoint attachment survives canonical projection
- **GIVEN** discovery has identified a managed infrastructure device and one or more downstream client endpoints
- **WHEN** canonical topology projection runs
- **THEN** the AGE read model SHALL retain an endpoint attachment relation between the infrastructure device and each discovered endpoint
- **AND** each relation SHALL remain queryable with canonical source and target device identifiers for God-View consumption

#### Scenario: Endpoint attachments do not replace backbone adjacency
- **GIVEN** a topology segment contains both infrastructure-to-infrastructure links and infrastructure-to-endpoint attachments
- **WHEN** canonical topology is queried for rendering
- **THEN** backbone adjacency SHALL remain represented as backbone topology
- **AND** endpoint attachments SHALL remain represented as separate endpoint attachment relations instead of overwriting or hiding backbone links
