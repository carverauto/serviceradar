## MODIFIED Requirements

### Requirement: Mapper interfaces ingestion handles TimescaleDB constraint naming
The mapper interfaces ingestor SHALL handle unique constraint violations from TimescaleDB hypertables gracefully, regardless of chunk-prefixed constraint names.

#### Scenario: Duplicate interface in same batch
- **GIVEN** a batch of interface records with duplicates (same timestamp, device_id, interface_uid)
- **WHEN** the batch is ingested
- **THEN** duplicates are deduplicated before insert and ingestion succeeds

#### Scenario: Interface already exists in database
- **GIVEN** an interface record that already exists in the database
- **WHEN** a new record with the same primary key is ingested
- **THEN** the conflict is handled gracefully (upsert or skip) without raising an exception

#### Scenario: Conflict on TimescaleDB chunk
- **GIVEN** interface records spanning multiple TimescaleDB chunks
- **WHEN** a constraint violation occurs with chunk-prefixed name (e.g., "1_2_discovered_interfaces_pkey")
- **THEN** the error is handled as a duplicate and the record is skipped

#### Scenario: Partial batch success
- **GIVEN** a batch where some records conflict and others are new
- **WHEN** the batch is ingested
- **THEN** non-conflicting records are inserted successfully and conflicts are logged
