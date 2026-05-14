## ADDED Requirements

### Requirement: Identity Cache Caller Policy
The system SHALL treat the identity cache as an explicit optimization and SHALL require each cache caller to declare whether stale data can affect inventory mutation, reconciliation, promotion, or suppression decisions.

#### Scenario: Ingestion caller resolves identity
- **WHEN** an ingestion workflow prepares to create, update, merge, promote, or suppress a device
- **THEN** the workflow SHALL use authoritative CNPG/DIRE identity lookup
- **AND** it SHALL NOT trust a cached device mapping unless that mapping was refreshed or validated within the same operation.

#### Scenario: Read-only enrichment uses cache
- **WHEN** a read-only enrichment path needs device metadata for metrics or status annotation
- **AND** a stale lookup cannot mutate inventory or change canonical identity
- **THEN** the path MAY use the identity cache
- **AND** it SHALL fall back to authoritative lookup when the cache misses.

### Requirement: Identity Cache Freshness and Invalidation
The system SHALL invalidate or refresh identity cache entries whenever canonical device identity, active IP mappings, identifiers, aliases, or lifecycle state changes.

#### Scenario: Active IP changes
- **GIVEN** a device has an active IP cached for identity lookup
- **WHEN** the device active IP is changed
- **THEN** cache entries for both the old IP and new IP SHALL be invalidated or refreshed after the database change succeeds.

#### Scenario: Device lifecycle changes
- **WHEN** a device is created, soft-deleted, restored, merged, or unmerged
- **THEN** cache entries that could resolve to the affected device IDs or IPs SHALL be invalidated or refreshed
- **AND** future ingestion lookups SHALL NOT resolve to a deleted or non-canonical device.

#### Scenario: Identifier or alias changes
- **WHEN** a strong identifier is assigned, reassigned, removed, or an IP alias is confirmed
- **THEN** cache entries that could resolve through those identifiers or aliases SHALL be invalidated or refreshed.

### Requirement: Stale Cache Regression Coverage
The system SHALL include regression tests that intentionally seed stale identity-cache entries and verify authoritative ingestion behavior wins.

#### Scenario: Stale IP cache points at missing device
- **GIVEN** the identity cache maps an IP address to a device ID that is absent or soft-deleted in CNPG
- **WHEN** an ingestion workflow processes a result for that IP
- **THEN** the workflow SHALL ignore the stale cache entry for mutation decisions
- **AND** it SHALL resolve or create the correct authoritative device.

#### Scenario: Stale IP cache points at wrong active device
- **GIVEN** the identity cache maps an IP address to device A
- **AND** CNPG authoritatively maps that active IP to device B
- **WHEN** an ingestion workflow processes a result for that IP
- **THEN** the workflow SHALL use device B
- **AND** it SHALL record a cache stale or authoritative fallback diagnostic.

### Requirement: Identity Lookup Observability
The system SHALL expose diagnostics for identity cache use and authoritative fallback decisions in ingestion paths.

#### Scenario: Large ingestion run completes
- **WHEN** a large integration or sweep ingestion run completes
- **THEN** diagnostics SHALL include cache hit count, cache miss count, stale cache rejection count, authoritative lookup count, and affected device count.
