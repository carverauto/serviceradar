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

### Requirement: Merge Preserves Inventory Associations
The system SHALL reassign inventory-linked records to the canonical device ID during a merge.

#### Scenario: Interface records move to canonical device
- **GIVEN** two device IDs that each have `discovered_interfaces` records
- **WHEN** DIRE merges the non-canonical device into the canonical device
- **THEN** all `discovered_interfaces` records SHALL reference the canonical device ID
