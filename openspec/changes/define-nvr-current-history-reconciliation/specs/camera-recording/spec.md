## ADDED Requirements

### Requirement: Explicit local recording history recovery gate
The system SHALL keep supported Core or retained-volume snapshot/PITR recovery behind an explicit deployment recovery gate established outside the restored data set. Historical bootstrap, registration and completion receipts SHALL NOT reopen current admission by themselves.

#### Scenario: Ordinary worker replacement retains current history
- **WHEN** a qualified replacement exclusively attaches the original storage lifetime after verified writer retirement and reconciles it against current authoritative history
- **THEN** the system SHALL retain its history identity and recovery generation
- **AND** it SHALL NOT require a new recovery generation solely because the serving worker changed

#### Scenario: Core and volume are restored to a matching older checkpoint
- **WHEN** the supported recovery workflow restores Core, an NVR volume, or both from snapshots or backups
- **THEN** it SHALL close affected admission and establish a fresh deployment recovery generation before restored workloads serve traffic
- **AND** matching older receipts SHALL NOT establish current history eligibility
- **AND** unresolved publication, preservation or disposition history SHALL preserve bytes and refuse publication, advertised playback and destructive operations

#### Scenario: Recovery control cannot establish current authority
- **WHEN** deployment recovery state is unavailable, inconsistent across serving replicas, or restored with the data whose rollback it must fence
- **THEN** affected admission SHALL remain closed until the supported recovery procedure establishes a fresh closed generation and verifies authoritative history
- **AND** application startup SHALL NOT synthesize ready state from restored database rows or local files

### Requirement: Bounded current-history reconciliation
The system SHALL reconcile bounded retained history against authoritative publication, preservation and disposition history before committing current-generation completion for a storage lifetime. Completion SHALL bind the exact comparison head and SHALL NOT grant independent qualification, ownership, capture or playback authority.

#### Scenario: History changes during reconciliation
- **WHEN** an operation advances authoritative history after the reconciler selects its comparison head
- **THEN** Core SHALL refuse completion against that stale head
- **AND** the reconciler SHALL resume or restart bounded comparison without overwriting retained evidence

#### Scenario: Retained history or restore provenance is incomplete
- **WHEN** a retained tail, hold, release or deletion commitment cannot be verified against authoritative history covering the supported restore horizon
- **THEN** the system SHALL preserve the affected bytes and report unresolved recovery
- **AND** it SHALL NOT create empty-history genesis or reconstruct authority solely from local checksums

#### Scenario: Domain operations compete with history completion
- **WHEN** registration, preservation or disposition changes compete with reconciliation completion
- **THEN** Core SHALL serialize the authoritative change and history head in the owning transaction
- **AND** network and filesystem operations SHALL remain outside that transaction
