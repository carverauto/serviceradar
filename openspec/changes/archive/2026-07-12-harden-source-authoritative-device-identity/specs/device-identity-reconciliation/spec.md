## ADDED Requirements

### Requirement: Source-Authoritative Identifier Integrity
The system SHALL treat typed stable identifiers from source integrations as source-authoritative device identity and SHALL NOT silently reassign them to unrelated device rows because of weak IP evidence.

#### Scenario: Generic source-authoritative integration update collides with unrelated active IP owner
- **GIVEN** an integration sync update contains source-scoped `integration_id = A` and IP `I`
- **AND** active IP `I` is already owned by device `D2`
- **AND** `D2` does not already carry integration ID `A` or another allowed non-MAC strong identifier match for the incoming update
- **WHEN** identity reconciliation processes the update
- **THEN** the system SHALL NOT reassign integration ID `A` to `D2`
- **AND** it SHALL preserve the source-authoritative mapping for integration ID `A`
- **AND** it SHALL not use IP evidence alone to merge those devices

#### Scenario: Armis update collides with unrelated active IP owner
- **GIVEN** an Armis sync update contains `armis_device_id = A`, MAC `M1`, and IP `I`
- **AND** active IP `I` is already owned by device `D2`
- **AND** `D2` does not already carry Armis Device ID `A` or another allowed non-MAC strong identifier match for the incoming update
- **WHEN** identity reconciliation processes the update
- **THEN** the system SHALL NOT reassign Armis Device ID `A` to `D2`
- **AND** it SHALL preserve the source-authoritative mapping for Armis Device ID `A`
- **AND** it SHALL record a source identity conflict or retire the stale IP owner only when policy can prove the owner is safe to retire

#### Scenario: DHCP churn for same Armis device
- **GIVEN** an existing canonical device has Armis Device ID `A`
- **AND** a later Armis sync update for Armis Device ID `A` reports a new IP address
- **WHEN** identity reconciliation processes the update
- **THEN** the update SHALL resolve to the existing canonical device for `A`
- **AND** the new IP evidence SHALL NOT create or rebind a second canonical device for `A`

### Requirement: Strong Source Identity Wins Over Active-IP Recovery
Active-IP uniqueness recovery SHALL be limited to weak or policy-approved cases and SHALL NOT use IP collision recovery to move source-authoritative identifiers between unrelated devices.

#### Scenario: Active-IP retry would move typed source identifier
- **GIVEN** a bulk sync insert hits the active-IP unique constraint
- **AND** one of the incoming records has a typed source-authoritative identifier
- **AND** the existing active-IP owner does not match that typed identifier
- **WHEN** the retry path chooses how to recover
- **THEN** it SHALL NOT rewrite the incoming record's identifier rows to the existing active-IP owner
- **AND** it SHALL emit an identity conflict diagnostic that includes the incoming source identifier, incoming IP, existing device UID, and existing identifiers

#### Scenario: Weak IP-only update can still reuse existing row
- **GIVEN** an incoming update has no strong source identifier
- **AND** active IP `I` already belongs to an existing non-deleted device
- **WHEN** identity reconciliation processes the update
- **THEN** the system MAY reuse the existing active-IP row according to the existing weak identity policy

### Requirement: Source Identity Drift Detection
The system SHALL detect source identity drift where source identifiers, generic integration identifiers, and device metadata disagree.

#### Scenario: One device carries multiple Armis identifiers
- **GIVEN** an active device has more than one distinct `armis_device_id` identifier
- **WHEN** the identity drift audit runs
- **THEN** the system SHALL report the device as conflicted
- **AND** automated northbound actions SHALL NOT collapse those identifiers into one outbound device update until the conflict is resolved

#### Scenario: Metadata disagrees with typed identifier
- **GIVEN** a device metadata field `armis_device_id` differs from the device's typed `armis_device_id` identifier
- **WHEN** the identity drift audit runs
- **THEN** the system SHALL report the metadata/identifier disagreement
- **AND** repair tooling SHALL either update stale metadata to match the single typed identifier or leave an unresolved conflict when the correct identity is ambiguous

#### Scenario: Typed and generic source identifiers split
- **GIVEN** Armis Device ID `A` appears as a typed `armis_device_id` identifier on one device
- **AND** the same value appears as a generic `integration_id` identifier on another active device for the same Armis source
- **WHEN** the identity drift audit runs
- **THEN** the system SHALL report the split mapping
- **AND** identity reconciliation SHALL NOT treat both rows as valid candidates for the same source device
