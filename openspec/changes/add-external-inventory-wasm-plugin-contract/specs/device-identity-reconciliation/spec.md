## ADDED Requirements

### Requirement: Stable source-authoritative external identifiers
DIRE SHALL register each valid external source object with one stable source-prefixed integration identifier containing a source instance and object ID. The identifier SHALL remain stable across polling runs, endpoint renames, credential rotation, IP changes, and hostname changes and SHALL follow existing conflict and audited-rebinding rules.

#### Scenario: Source device changes address
- **GIVEN** an external source object has an existing integration identifier
- **AND** a later complete snapshot reports a different IP or hostname for the same object ID
- **WHEN** DIRE processes the observation
- **THEN** it SHALL resolve to the same canonical device
- **AND** it SHALL not mint another source integration identifier

#### Scenario: Object ID is reused across instances
- **GIVEN** two configured source instances report the same object ID
- **WHEN** DIRE registers their integration identifiers
- **THEN** the instance component SHALL keep them distinct
- **AND** they SHALL not converge without independent shared strong evidence

### Requirement: Manufacturer-scoped hardware serial identity
DIRE SHALL support validated manufacturer-scoped hardware serial identifiers as cross-source identity evidence. Blank, placeholder, all-zero, multi-value, overlong, or known non-unique serials SHALL NOT be registered as strong identifiers. A serial without a trustworthy vendor namespace SHALL NOT independently merge devices.

#### Scenario: Two sources report the same switch serial
- **GIVEN** an existing canonical device has a valid vendor-scoped hardware serial
- **AND** an external inventory observation reports the same canonical vendor and serial
- **WHEN** DIRE processes the observation
- **THEN** it SHALL resolve the existing canonical UID
- **AND** it SHALL attach the external source identifier while preserving prior identifiers

#### Scenario: Conflicting strong identities share an IP
- **GIVEN** two source observations share an IP or hostname
- **AND** their valid manufacturer-scoped serials differ
- **WHEN** DIRE evaluates convergence
- **THEN** it SHALL NOT merge or move either source identifier based on weak evidence
- **AND** it SHALL report an identity conflict

#### Scenario: Placeholder serial is ignored
- **GIVEN** a source reports an invalid or known-placeholder serial
- **WHEN** identity evidence is extracted
- **THEN** the value MAY remain bounded display metadata
- **AND** it SHALL NOT trigger a strong-identity merge

### Requirement: Device source observations follow canonical merges
Source-observation records SHALL reference canonical device UIDs and SHALL be reassigned to the winning UID during DIRE merges without changing source instance, source object ID, collection, or observation history.

#### Scenario: Later evidence merges a source-only device
- **GIVEN** an external source observation initially points to a separate canonical device
- **AND** later strong evidence causes DIRE to merge it into another canonical device
- **WHEN** the merge commits
- **THEN** the source observation SHALL reference the winning canonical UID
- **AND** its source identity and history SHALL remain intact
