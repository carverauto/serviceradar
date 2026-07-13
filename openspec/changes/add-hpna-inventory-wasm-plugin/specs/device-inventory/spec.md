## ADDED Requirements

### Requirement: Indexed current device source observations
The system SHALL persist bounded source-observation state keyed by partition, discovery source, source instance, and source object ID. Each observation SHALL reference a canonical device UID and track first seen, last observed, current collection, present/absent state, and source-specific non-secret metadata with indexes for current inventory reads.

#### Scenario: HPNA object is first observed
- **WHEN** a complete HPNA snapshot introduces a source object
- **THEN** ServiceRadar SHALL upsert one `hpna` source observation linked to the DIRE-resolved canonical UID
- **AND** it SHALL mark the observation present with the current collection and observed time

#### Scenario: Same collection is ingested twice
- **GIVEN** an HPNA source instance, object ID, collection ID, and content hash were already ingested
- **WHEN** command retry delivers the same result again
- **THEN** the source observation and canonical device SHALL remain idempotent
- **AND** no duplicate rows or discovery-source entries SHALL be created

#### Scenario: Object is absent from a later complete snapshot
- **GIVEN** an HPNA source object was present in the previous complete collection
- **WHEN** a later complete collection for the same instance omits it
- **THEN** its HPNA observation SHALL become absent
- **AND** its canonical device SHALL not be deleted, tombstoned, or made unavailable solely because HPNA omitted it

#### Scenario: Incomplete snapshot does not mark absence
- **GIVEN** HPNA collection fails or is explicitly incomplete
- **WHEN** ingestion handles the result
- **THEN** current source observations SHALL remain unchanged
- **AND** no observation SHALL be marked absent

### Requirement: Multi-source canonical provenance preservation
Canonical device upserts SHALL union discovery sources and preserve source-specific provenance. Adding HPNA to an existing Armis device SHALL NOT overwrite or erase Armis identifiers, metadata, currentness, or attachment evidence with generic plugin integration fields.

#### Scenario: HPNA enriches an Armis device
- **GIVEN** DIRE resolves an HPNA observation to an existing Armis canonical UID
- **WHEN** inventory persistence completes
- **THEN** `discovery_sources` SHALL contain both `armis` and `hpna`
- **AND** Armis source metadata SHALL remain unchanged except for independently governed canonical fields
- **AND** HPNA fields SHALL be stored under stable HPNA-specific keys or source-observation metadata

#### Scenario: HPNA is the first source
- **GIVEN** HPNA discovers a device not known to another source
- **WHEN** it is ingested
- **THEN** the canonical device SHALL contain `hpna` as a discovery source
- **AND** later Armis discovery with matching strong evidence SHALL add `armis` without losing HPNA provenance

### Requirement: Searchable HPNA inventory and freshness
Authorized users SHALL be able to browse and filter current HPNA observations and their canonical devices by source instance, source object ID, hostname, IP, vendor, model, device type, partition/site, management state, collection, and freshness. Query paths SHALL be indexed and bounded.

#### Scenario: SRQL finds HPNA devices
- **WHEN** an authorized user queries devices with `discovery_sources:(hpna)`
- **THEN** ServiceRadar SHALL return canonical devices discovered by HPNA
- **AND** HPNA-specific metadata filters SHALL be available for supported fields

#### Scenario: Operator views merged source details
- **GIVEN** a canonical device was discovered by both Armis and HPNA
- **WHEN** an operator opens its integration/provenance details
- **THEN** the UI SHALL show both sources
- **AND** it SHALL show HPNA instance, device ID, partition, management state, last collection, and freshness without exposing credentials

### Requirement: Authenticated source-inventory API
ServiceRadar SHALL expose an authenticated, authorization-scoped, cursor-paginated API for reading source observations joined to canonical device fields. The API SHALL support bounded source, instance, presence, and collection filters and SHALL return present observations by default.

#### Scenario: NCO reads current HPNA inventory
- **GIVEN** NCO presents a valid ServiceRadar bearer token with device read permission
- **WHEN** it requests present observations for source `hpna` and an allowed instance
- **THEN** the API SHALL return bounded pages containing canonical UID and normalized HPNA inventory fields
- **AND** it SHALL return collection/snapshot identity and pagination metadata

#### Scenario: Unauthorized source read
- **WHEN** a caller lacks authentication or device inventory permission
- **THEN** the API SHALL reject the request
- **AND** it SHALL not reveal device, credential, schedule, or source configuration data

#### Scenario: Unsafe query input
- **WHEN** a caller supplies an unsupported filter, excessive limit, malformed cursor, or SQL-like input
- **THEN** the API SHALL reject or safely normalize the request through typed filters
- **AND** it SHALL never interpolate caller input into SQL
