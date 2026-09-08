## ADDED Requirements

### Requirement: Multi-Identifier Convergence
The system SHALL reconcile device updates that contain multiple strong identifiers to a single canonical device ID, even when those identifiers currently map to different devices, within the same partition.

#### Scenario: Conflicting MAC identifiers merge into one device
- **GIVEN** a device update in partition `default` containing MAC A and MAC B
- **AND** MAC A maps to device ID X while MAC B maps to device ID Y
- **WHEN** DIRE processes the update
- **THEN** DIRE SHALL select a canonical device ID
- **AND** all identifiers (MAC A and MAC B) SHALL be assigned to the canonical device
- **AND** a `merge_audit` entry SHALL record the merge from the non-canonical device to the canonical device

### Requirement: Interface MAC Registration
The system SHALL register MAC addresses discovered on a device's interfaces as strong identifiers for that device within the device's partition.

#### Scenario: Interface MACs prevent duplicate devices
- **GIVEN** a mapper or sweep update that includes a list of interface MAC addresses for a device
- **WHEN** DIRE registers identifiers for the device
- **THEN** each interface MAC SHALL be inserted into `device_identifiers` for the device's partition
- **AND** subsequent updates that include any of those MACs SHALL resolve to the same device ID

### Requirement: IP Alias Resolution
The system SHALL resolve IP-only device updates using confirmed IP aliases before generating a new device ID.

#### Scenario: Interface-discovered IP alias resolves a sweep host
- **GIVEN** a device `sr:<uuid>` has a confirmed IP alias `216.17.46.98` recorded from interface discovery
- **WHEN** a sweep result arrives with host IP `216.17.46.98` and no strong identifiers
- **THEN** DIRE SHALL resolve the update to the canonical device ID
- **AND** SHALL NOT create a new device record for the alias IP

#### Scenario: Strong-ID update conflicts with confirmed IP alias
- **GIVEN** a device update with a strong identifier resolves to device ID X
- **AND** the update IP is a confirmed alias for device ID Y (Y != X)
- **WHEN** DIRE processes the update
- **THEN** DIRE SHALL merge the alias device into the strong-ID canonical device

### Requirement: IP Alias Sightings and Promotion
The system SHALL track IP alias sightings for weak identifiers and only promote aliases once they meet a configurable confirmation threshold.

#### Scenario: Alias remains pending until confirmed
- **GIVEN** a mapper interface update reports IP `192.168.10.1` as an interface address for device `sr:<uuid>`
- **WHEN** the alias has been sighted fewer times than the confirmation threshold
- **THEN** the alias SHALL remain in a pending state and SHALL NOT be used for canonical resolution

#### Scenario: Alias becomes active after confirmation
- **GIVEN** an IP alias has been sighted at or above the confirmation threshold
- **WHEN** the alias is processed
- **THEN** the alias SHALL be marked confirmed and eligible for identity resolution

### Requirement: Scheduled Reconciliation Backfill
The system SHALL run a scheduled reconciliation job that merges existing duplicate devices sharing strong identifiers and logs summary statistics for each run.

#### Scenario: Scheduled reconciliation merges duplicates and logs results
- **GIVEN** two device IDs that share the same strong identifier within a partition
- **WHEN** the reconciliation job runs
- **THEN** the non-canonical device SHALL be merged into the canonical device
- **AND** the job SHALL emit logs summarizing the number of duplicates scanned and merges performed

### Requirement: Merge Preserves Inventory Associations
The system SHALL reassign inventory-linked records to the canonical device ID during a merge.

#### Scenario: Interface records move to canonical device
- **GIVEN** two device IDs that each have `discovered_interfaces` records
- **WHEN** DIRE merges the non-canonical device into the canonical device
- **THEN** all `discovered_interfaces` records SHALL reference the canonical device ID
