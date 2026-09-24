## ADDED Requirements

### Requirement: Indexed current device source observations
The system SHALL stage bounded source-observation pages by authenticated installation partition, discovery source, source instance, coverage scope, and run. It SHALL expose current observations through one atomic current-version pointer per source instance and coverage scope. Each activated observation SHALL be keyed by source object ID, reference a canonical device UID, and track first seen, last observed, current collection, present/absent state, standard device values, and bounded provider-owned metadata. Staged pages MUST NOT become current individually.

#### Scenario: Source object is first observed
- **WHEN** a validated complete external inventory terminal atomically activates a staged snapshot that introduces a source object
- **THEN** ServiceRadar SHALL upsert one source observation linked to the DIRE-resolved canonical UID
- **AND** it SHALL mark the observation present with the current collection and observed time

#### Scenario: Same collection is delivered twice
- **GIVEN** a source instance, object ID, collection ID, and content hash were already ingested
- **WHEN** producer or broker retry delivers the same page or terminal again
- **THEN** source observations and canonical devices SHALL remain idempotent
- **AND** no duplicate rows or discovery-source entries SHALL be created

#### Scenario: Object is absent from a later snapshot
- **GIVEN** a source object was present in the previous complete collection
- **AND** the provider consistency proof authorizes absence for the exact same coverage scope
- **WHEN** a later complete collection for the same source instance and scope omits it
- **THEN** its observation SHALL become absent
- **AND** its canonical device SHALL not be deleted or made unavailable solely because one source omitted it

#### Scenario: Ordinary discovery is not a complete snapshot
- **GIVEN** a discovery envelope does not declare a complete source snapshot
- **WHEN** ingestion processes it
- **THEN** canonical discovery MAY proceed normally
- **AND** current source-observation presence SHALL remain unchanged

#### Scenario: A staged run is incomplete or stale
- **GIVEN** source pages were staged for a run
- **WHEN** the run aborts, expires, loses a page, fails its consistency proof, or its terminal is older than the current version
- **THEN** no current-version pointer SHALL change
- **AND** the previous source snapshot SHALL remain queryable while the staged run awaits bounded garbage collection

### Requirement: Multi-source canonical provenance preservation
Canonical device upserts SHALL union discovery sources and preserve source-specific provenance. A complete plugin inventory SHALL NOT replace another source's canonical integration identity with generic or provider integration fields.

#### Scenario: External inventory enriches an existing device
- **GIVEN** DIRE resolves an external observation to an existing canonical UID from another source
- **WHEN** inventory persistence completes
- **THEN** `discovery_sources` SHALL contain both sources
- **AND** existing source identity and metadata SHALL remain intact

#### Scenario: External inventory is the first source
- **GIVEN** an external plugin discovers a device not known to another source
- **WHEN** it is ingested
- **THEN** the canonical device SHALL record that discovery source
- **AND** later strong evidence from another source SHALL add provenance without losing the first source observation

### Requirement: Authenticated generic source-inventory API
ServiceRadar SHALL expose an authenticated, authorization-scoped, cursor-paginated API for source observations joined to canonical device fields. The API SHALL require bounded source and instance identifiers, support typed presence and collection filters, and return present observations by default.

#### Scenario: Authorized client reads current source inventory
- **GIVEN** a caller presents a valid bearer token with device read permission
- **WHEN** it requests one allowed source and instance
- **THEN** the API SHALL return bounded collection-consistent pages with canonical and source identity
- **AND** it SHALL return source metadata, snapshot identity, and pagination state without provider-specific response code

#### Scenario: Unauthorized source read
- **WHEN** a caller lacks authentication or device inventory permission
- **THEN** the API SHALL reject the request
- **AND** it SHALL not reveal device, credential, schedule, or source configuration data

#### Scenario: Unsafe query input
- **WHEN** a caller supplies an unsupported filter, excessive limit, malformed cursor, or SQL-like input
- **THEN** the API SHALL reject the request through typed validation
- **AND** caller input SHALL never be interpolated into SQL
