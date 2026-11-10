## ADDED Requirements

### Requirement: Deployment-owned local storage qualification
The system SHALL require authenticated deployment-owned qualification of the exact storage lifetime, binding generation and provider profile before accepting a new local-copy registration. Recorder content verification, intent acceptance and successful report parsing SHALL NOT grant qualification authority.

#### Scenario: Recorder claims its own storage is safe
- **WHEN** an authenticated recorder submits a passing qualification claim without activation by an authorized deployment qualification principal
- **THEN** Core SHALL refuse to treat that claim as current storage qualification
- **AND** the original intent and local media SHALL remain preserved for reconciliation

#### Scenario: Storage profile or eligibility changes
- **WHEN** the bound provider resource/profile changes, qualification is withdrawn or expires, or current health evidence is missing or too old
- **THEN** new copy registration SHALL be refused until the exact generation is qualified and eligible
- **AND** historical registration SHALL remain distinct from current playback eligibility
- **AND** qualification withdrawal SHALL NOT delete media, release preservation or establish writer retirement
- **AND** expired qualification or reduced replica health alone SHALL NOT prevent reads of a historical registered copy when all independent owner, integrity, history and authorization gates still pass

#### Scenario: Fully on-prem qualification
- **WHEN** a deployment uses qualified customer-operated filesystem storage
- **THEN** qualification and local-copy registration SHALL operate without S3 or a SaaS entitlement service
- **AND** the provider SHALL own media replication and physical worker-node/local-disk recovery

### Requirement: Distinct immutable local-copy registration
The system SHALL register a local recording copy through a distinct immutable operation bound to the accepted intent, original frozen authority, exact storage qualification and reconciled history checkpoint. The v1 intent acknowledgement and S3 archive evidence SHALL retain their existing meanings.

#### Scenario: Register a qualified copy
- **WHEN** authenticated storage-bound submission matches synced verified local evidence, frozen recording authority, current qualification and consistent preservation/disposition history
- **THEN** Core SHALL atomically commit one local-copy registration and return a canonical operation/content-bound acknowledgement after commit
- **AND** the NVR SHALL durably retain that acknowledgement before marking delivery complete
- **AND** file/network operations SHALL NOT run inside the catalog transaction

#### Scenario: Retry after acknowledgement loss and later withdrawal
- **WHEN** the identical committed registration is retried after its response was lost, including after qualification is withdrawn
- **THEN** Core SHALL return the same historical registration acknowledgement
- **AND** that receipt SHALL NOT restore current qualification, reachability or playback permission
- **AND** changed content or qualification under the same operation UUID SHALL conflict without overwriting the original evidence

#### Scenario: Restore cannot prove preservation history
- **WHEN** Core or a retained volume is restored with missing, older or inconsistent publication/preservation/disposition history
- **THEN** publication and advertised playback SHALL remain unresolved until authoritative reconciliation completes
- **AND** the system SHALL preserve surviving bytes and refuse destructive operations
- **AND** initial empty-history bootstrap SHALL NOT be applied to an existing spool because its history file is absent

#### Scenario: Registered copy cannot serve an authorized read
- **WHEN** current owner/read readiness, fresh interval authorization, preservation/read admission or requested-byte verification fails
- **THEN** the system SHALL report the applicable unavailable or denied state without presenting the historical registration as playable availability
- **AND** fallback SHALL require a separately verified currently authorized copy
