## ADDED Requirements

### Requirement: Explicit persistent recording installation
The system SHALL keep the default core Deployment unchanged and provide an explicitly selected persistent-spool installation with one retained volume per StatefulSet member without automatically enabling recording.

#### Scenario: Default installation
- **WHEN** persistent recording storage is not explicitly selected
- **THEN** the chart SHALL render the existing core Deployment without a recording spool or initializer
- **AND** recording SHALL remain disabled by default

#### Scenario: Unsupported or unverified storage
- **WHEN** the selected driver cannot enforce the required exclusive pod mount or the bound volume's retention/encryption contract is unverified
- **THEN** provisioning SHALL refuse readiness
- **AND** SHALL NOT substitute shared, host-local or ephemeral storage

### Requirement: Provisioned per-volume installation identity
The system SHALL select each member's expected storage UUID from explicit versioned installation configuration and initialize the intended volume only through a separate exclusive provisioning operation.

#### Scenario: Replacement or conflicting identity
- **WHEN** a member has an absent or ambiguous identity mapping, a substituted volume, or an absent/conflicting marker
- **THEN** recording admission SHALL fail
- **AND** normal startup SHALL NOT generate an identity, adopt the marker, initialize storage or repair retained bytes

#### Scenario: Exact provisioning retry
- **WHEN** an exclusive initializer retries against the same retained volume and expected UUID
- **THEN** it SHALL follow the existing exact marker verification contract without rewriting a valid marker
- **AND** partial, conflicting or unmarked nonempty storage SHALL remain preserved for reconciliation

### Requirement: Preservation across controller and lifecycle changes
The system SHALL preserve recording claims and their storage-lifetime inventory across scale-down, rollback and workload removal, and require observed old-owner retirement before controller conversion or replacement writers.

#### Scenario: Interrupted conversion or rollback
- **WHEN** conversion between the core Deployment and StatefulSet is interrupted or rolled back
- **THEN** the procedure SHALL refuse simultaneous old and new owners and preserve all recording volumes
- **AND** recovery SHALL NOT treat a stop request or a controller manifest as proof that the old writer has exited

#### Scenario: Core scale-down or uninstall
- **WHEN** a core member is removed or its workload is uninstalled
- **THEN** its claim, backing volume and inventory SHALL remain retained
- **AND** deletion SHALL require the separate preservation-aware lifecycle authority

### Requirement: Controller-aware hosted recording readiness
The control plane SHALL verify the installed core controller kind, per-member storage identities and preservation state before declaring persistent recording installation ready, including in restore planning and execution.

#### Scenario: Restore encounters a different controller kind
- **WHEN** a restore plan's core controller kind is unknown, ambiguous or differs from the installed workload
- **THEN** restore execution SHALL refuse that target without silently applying a Deployment operation to a StatefulSet
- **AND** retained media inventory SHALL remain preserved

#### Scenario: Local storage installed without archive qualification
- **WHEN** persistent spools are installed but provider qualification or archive authority is missing
- **THEN** hosted archive readiness SHALL remain unavailable
- **AND** a local capture receipt SHALL NOT imply uploaded, published or playable archive media

