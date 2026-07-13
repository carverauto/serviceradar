## ADDED Requirements

### Requirement: Stable source-authoritative HPNA identifiers
DIRE SHALL register each valid HPNA source object with one stable source-authoritative integration identifier formatted from version, HPNA instance, and HPNA device ID. The identifier SHALL remain stable across polling runs, endpoint renames, credential rotation, IP changes, and hostname changes, and SHALL be subject to existing source-identity conflict and audited-rebinding rules.

#### Scenario: Same HPNA device changes IP
- **GIVEN** an HPNA object identified as `hpna:v1:example-automation-prod:device:201`
- **AND** a later complete snapshot reports a different IP or hostname for device 201
- **WHEN** DIRE processes the later observation
- **THEN** it SHALL resolve to the same canonical device
- **AND** it SHALL update HPNA source metadata without minting another HPNA integration identifier

#### Scenario: HPNA device ID is reused across instances
- **GIVEN** two configured HPNA instances both report device ID 201
- **WHEN** DIRE registers their source identifiers
- **THEN** the instance component SHALL keep the identifiers distinct
- **AND** they SHALL not converge unless independent shared hardware evidence proves they are the same device

### Requirement: Manufacturer-scoped hardware serial identity
DIRE SHALL support validated manufacturer-scoped hardware serial identifiers as cross-source identity evidence. The identifier value SHALL be built from a canonical vendor namespace and normalized serial. Blank, placeholder, all-zero, multi-value, overlong, or known non-unique serials SHALL NOT be registered as strong identifiers. A serial without a trustworthy vendor namespace SHALL NOT independently merge devices.

#### Scenario: Armis and HPNA report the same switch serial
- **GIVEN** an existing Armis canonical device has a valid vendor-scoped hardware serial
- **AND** HPNA reports the same canonical vendor and serial for one HPNA device
- **WHEN** DIRE processes the HPNA observation
- **THEN** it SHALL resolve the existing Armis canonical UID
- **AND** it SHALL attach the HPNA source identifier and preserve the Armis identifier

#### Scenario: Canonical vendor aliases match
- **GIVEN** two sources use approved aliases that normalize to the same hardware vendor
- **AND** both report the same valid serial
- **WHEN** serial identifiers are built
- **THEN** both SHALL produce the same manufacturer-scoped identifier

#### Scenario: Placeholder serial is ignored
- **GIVEN** HPNA reports a blank, `unknown`, `n/a`, all-zero, multi-value, or otherwise invalid serial
- **WHEN** identity evidence is extracted
- **THEN** the value MAY remain bounded display metadata
- **AND** it SHALL NOT be registered as a strong hardware serial or trigger a merge

#### Scenario: Duplicate serial is ambiguous
- **GIVEN** the same normalized manufacturer serial is already associated with multiple active canonical devices
- **WHEN** HPNA or a serial backfill presents that value
- **THEN** DIRE SHALL flag the identifier as conflicted and skip automatic convergence
- **AND** it SHALL emit bounded actionable diagnostics without silently rebinding the identifier

### Requirement: Conflict-safe HPNA cross-source convergence
HPNA reconciliation SHALL obey existing strong-identity, confidence, partition, cooldown, and source-authoritative merge guards. A shared valid hardware serial or globally unique MAC MAY converge sources; IP and hostname MAY corroborate but MUST NOT independently override distinct strong identities.

#### Scenario: Matching serial converges and keeps all sources
- **GIVEN** an Armis device and HPNA observation share a valid manufacturer-scoped serial
- **AND** no conflicting strong identifier or merge cooldown blocks convergence
- **WHEN** the HPNA snapshot is ingested
- **THEN** DIRE SHALL use one canonical UID
- **AND** its discovery sources SHALL contain both `armis` and `hpna`
- **AND** merge/identifier audit evidence SHALL identify the HPNA trigger

#### Scenario: Same IP but conflicting serials
- **GIVEN** an HPNA observation and existing Armis device have the same active IP
- **AND** their valid manufacturer-scoped serials differ
- **WHEN** DIRE processes the HPNA observation
- **THEN** it SHALL NOT merge or move either source-authoritative identifier based on IP
- **AND** it SHALL report an identity conflict

#### Scenario: Only IP and hostname match
- **GIVEN** an HPNA observation has no valid shared hardware identifier
- **AND** its IP and hostname match a device holding an unrelated strong source identity
- **WHEN** DIRE processes the observation
- **THEN** it SHALL not force an automatic merge from that weak evidence alone
- **AND** later strong evidence SHALL remain able to converge the records

### Requirement: Hardware serial backfill is bounded and auditable
The system SHALL provide a dry-run-first bounded backfill that extracts valid manufacturer-scoped serial evidence from existing canonical device metadata. Execute mode SHALL register only unambiguous identifiers and SHALL record source, prior metadata, canonical device UID, normalization result, and conflicts.

#### Scenario: Unique existing Armis serial is registered
- **GIVEN** one active Armis device contains a valid vendor and serial in metadata
- **WHEN** the approved backfill executes
- **THEN** the corresponding manufacturer-scoped identifier SHALL be registered on that canonical UID
- **AND** the operation SHALL be auditable

#### Scenario: Backfill encounters duplicate serial
- **GIVEN** multiple active devices normalize to the same manufacturer-scoped serial
- **WHEN** the backfill evaluates them
- **THEN** it SHALL report and skip the conflicted identifier
- **AND** it SHALL not merge or rebind any affected device

### Requirement: Device source observations follow canonical merges
Source-observation records SHALL reference canonical device UIDs and SHALL be reassigned to the winning UID during DIRE merges without changing source instance, source object ID, collection, or observation history.

#### Scenario: Later evidence merges an HPNA-only device
- **GIVEN** an HPNA source observation initially points to a separate canonical device
- **AND** later strong evidence causes DIRE to merge it into an Armis canonical device
- **WHEN** the merge commits
- **THEN** the HPNA observation SHALL reference the winning canonical UID
- **AND** its source identity and history SHALL remain intact
