## ADDED Requirements

### Requirement: Structured WiFi-map plugin result batches

The SDK and external plugin contract SHALL support customer-owned plugins emitting structured WiFi-map batches that core-elx can ingest without executing plugin-provided display code.

#### Scenario: Customer CSV seed plugin emits a WiFi-map batch
- **GIVEN** a customer-owned WiFi-map plugin is configured in `csv_seed` mode with valid seed CSV inputs
- **WHEN** the agent executes the plugin
- **THEN** the plugin result SHALL include a versioned WiFi-map batch
- **AND** the batch SHALL include collection timestamp, source file metadata, site rows, AP rows, controller rows, RADIUS mappings, and fleet history rows when present
- **AND** the result status SHALL summarize the parsed row counts and validation failures

#### Scenario: Malformed seed rows are reported without aborting valid rows
- **GIVEN** a seed CSV contains a mix of valid rows and malformed rows
- **WHEN** the plugin parses the seed files
- **THEN** valid rows SHALL still be emitted
- **AND** malformed row details SHALL be included in bounded validation diagnostics
- **AND** the result status SHALL become `WARNING` when any rows are skipped

### Requirement: WiFi-map batch payload bounds

Customer WiFi-map plugins SHALL bound emitted batch size and SHALL use chunking or object handoff when the normalized payload would exceed the pipeline limit.

#### Scenario: Seed data exceeds direct payload limit
- **GIVEN** the normalized WiFi-map batch is larger than the configured direct plugin-result limit
- **WHEN** the plugin prepares the result
- **THEN** it SHALL split the inventory into ordered chunks or publish the batch through the approved object handoff path
- **AND** core-elx SHALL be able to reconstruct or ingest the batch without duplicate records

#### Scenario: Batch chunks preserve idempotency
- **GIVEN** the same chunked seed batch is delivered more than once
- **WHEN** core-elx ingests the chunks
- **THEN** site, AP, controller, RADIUS, history, and device identity records SHALL remain idempotent

### Requirement: Customer seed data access contract

The SDK/runtime contract SHALL provide a documented, reviewable way for customer plugins to consume CSV seed data without granting unrestricted agent filesystem access.

#### Scenario: Seed data is packaged with the plugin artifact
- **GIVEN** a customer WiFi-map plugin package includes seed CSV assets and declares them in its manifest or config schema
- **WHEN** the plugin runs in `csv_seed` mode
- **THEN** it SHALL read only the declared package assets
- **AND** the result SHALL include source asset names, content hashes, and parsed row counts

#### Scenario: Seed data uses host file permissions
- **GIVEN** a customer WiFi-map plugin requests seed CSV paths on the agent host
- **WHEN** an operator reviews the package and assignment
- **THEN** the system SHALL require explicit file-read capability and approved file roots before the plugin can read host files
- **AND** reads outside approved roots SHALL be denied by the agent runtime
