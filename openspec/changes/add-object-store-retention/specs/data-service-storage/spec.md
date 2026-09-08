## ADDED Requirements
### Requirement: Datasvc Object Metadata Inventory
Datasvc SHALL expose a read-only object metadata listing operation for ServiceRadar-owned JetStream Object Store buckets. The operation SHALL support prefix filtering, optional domain selection, bounded page size, and pagination, and it SHALL NOT return object payload bytes.

#### Scenario: Caller lists object metadata by prefix
- **GIVEN** datasvc stores objects under `agent-releases/1.2.48/`
- **WHEN** an authorized caller lists objects with prefix `agent-releases/`
- **THEN** datasvc returns object metadata records for matching keys
- **AND** the response excludes object payload data
- **AND** the response includes pagination state when additional objects remain

#### Scenario: Listing is bounded
- **GIVEN** a bucket contains more objects than the maximum allowed page size
- **WHEN** a caller requests all objects in one list request
- **THEN** datasvc caps the response to the configured maximum page size
- **AND** returns a token or offset for the next page

### Requirement: Datasvc Object Inventory Is RBAC Protected
Datasvc SHALL authorize object inventory requests using the same mTLS/RBAC model as object metadata reads, and it SHALL reject callers without an object reader or writer role.

#### Scenario: Unauthorized list request is rejected
- **GIVEN** a caller has no datasvc role that allows object metadata reads
- **WHEN** the caller requests object inventory
- **THEN** datasvc rejects the request
- **AND** no object keys or metadata are returned
