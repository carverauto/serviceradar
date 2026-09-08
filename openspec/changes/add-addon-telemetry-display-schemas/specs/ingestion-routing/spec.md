## ADDED Requirements

### Requirement: Ingestion preserves package signal schema metadata
The ingestion pipeline SHALL preserve package signal schema references attached to plugin or native add-on logs/events from producer emission through persistence. Agent, gateway, core, NATS processors, and database writers SHALL treat schema references as bounded presentation/provenance metadata and SHALL NOT require producer-specific routing code to retain them.

#### Scenario: Native add-on schema reference reaches event storage
- **GIVEN** a native add-on emits a telemetry record with a schema id and display contract version
- **WHEN** the agent forwards the record through gateway/core and db-event-writer
- **THEN** the persisted event SHALL retain the same schema/display reference
- **AND** gateway-attested partition, agent, and host metadata SHALL remain authoritative

#### Scenario: Malformed schema reference does not break ingest
- **GIVEN** a plugin or add-on emits an otherwise valid log/event with an invalid schema reference
- **WHEN** the ingestion pipeline validates bounded metadata
- **THEN** the pipeline SHALL strip or mark the invalid schema reference
- **AND** the log/event SHALL still be persisted when the canonical payload is valid

### Requirement: Schema references do not select write destinations
Schema/display references SHALL NOT control tenant routing, NATS subjects, database tables, RBAC decisions, or alert severity. Those decisions SHALL remain controlled by authenticated producer path, configured processors, and canonical payload fields.

#### Scenario: Add-on spoofs schema metadata
- **GIVEN** an add-on emits a telemetry record with schema metadata claiming a different producer or destination
- **WHEN** gateway/core process the record
- **THEN** tenancy and provenance SHALL be derived from the authenticated agent path and configured assignment
- **AND** the schema metadata SHALL be stored only as rendering/provenance metadata if it passes validation
