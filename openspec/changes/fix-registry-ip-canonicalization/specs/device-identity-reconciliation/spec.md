## ADDED Requirements

### Requirement: Strong identity (Armis ID) takes precedence over IP in conflict resolution

The registry SHALL use Armis ID as the authoritative device identifier. When an IP conflict occurs between two devices with different Armis IDs, the system SHALL NOT merge/tombstone either device but instead reassign the IP to the device that currently owns it according to the source system.

#### Scenario: IP reassignment between different Armis devices
- **GIVEN** `unified_devices` contains device sr:AAA with `armis_device_id=X` and `IP=10.0.0.1`
- **AND** an update arrives for device sr:BBB with `armis_device_id=Y` and `IP=10.0.0.1`
- **WHEN** the registry processes the update
- **THEN** sr:BBB is NOT tombstoned to sr:AAA (they are different devices)
- **AND** sr:AAA's IP is cleared (its IP is now stale)
- **AND** sr:BBB receives IP=10.0.0.1
- **AND** both devices remain canonical in inventory

#### Scenario: Same Armis device with changed IP
- **GIVEN** `unified_devices` contains device sr:AAA with `armis_device_id=X` and `IP=10.0.0.1`
- **AND** an update arrives with `armis_device_id=X` and `IP=10.0.0.2`
- **WHEN** the registry processes the update
- **THEN** sr:AAA's IP is updated to 10.0.0.2
- **AND** no tombstone is created
- **AND** the device remains canonical

#### Scenario: Duplicate update for same device (same IP, same Armis ID)
- **GIVEN** `unified_devices` contains device sr:AAA with `armis_device_id=X` and `IP=10.0.0.1`
- **AND** an update arrives with `armis_device_id=X` and `IP=10.0.0.1`
- **WHEN** the registry processes the update
- **THEN** sr:AAA is updated (last_seen, metadata, etc.)
- **AND** no new device is created
- **AND** no tombstone is created

### Requirement: IP conflicts within a batch respect strong identity

When multiple updates in the same batch have the same IP but different Armis IDs, the system SHALL treat them as distinct devices and resolve the IP ownership based on the source system's current state, not batch ordering.

#### Scenario: Intra-batch IP conflict with different Armis IDs
- **GIVEN** a batch contains:
  - Update A: `armis_device_id=X`, `IP=10.0.0.1`, `timestamp=T1`
  - Update B: `armis_device_id=Y`, `IP=10.0.0.1`, `timestamp=T2` (T2 > T1)
- **WHEN** the registry processes the batch
- **THEN** device Y receives IP=10.0.0.1 (most recent timestamp)
- **AND** device X has its IP cleared (not tombstoned)
- **AND** both devices remain in inventory as canonical

#### Scenario: Intra-batch IP conflict with same Armis ID
- **GIVEN** a batch contains duplicate updates for the same device:
  - Update A: `armis_device_id=X`, `IP=10.0.0.1`, `timestamp=T1`
  - Update B: `armis_device_id=X`, `IP=10.0.0.1`, `timestamp=T2`
- **WHEN** the registry processes the batch
- **THEN** only one device record exists (deduplicated by Armis ID)
- **AND** the most recent update's data is used

### Requirement: Tombstones are only for ID migration, not IP conflicts

The system SHALL only create tombstones (`_merged_into`) when migrating a device from a legacy ID format to a ServiceRadar UUID. Tombstones SHALL NOT be created due to IP address conflicts between distinct devices.

#### Scenario: Legacy ID migration creates tombstone
- **GIVEN** a device exists with legacy ID `default:10.0.0.1`
- **AND** an update arrives with `armis_device_id=X` resolving to `sr:AAA`
- **WHEN** the registry processes the update
- **THEN** a tombstone is created: `default:10.0.0.1` → `sr:AAA`
- **AND** future lookups for the legacy ID resolve to sr:AAA

#### Scenario: IP conflict does NOT create tombstone
- **GIVEN** device sr:AAA has IP=10.0.0.1
- **AND** device sr:BBB (different Armis ID) arrives with IP=10.0.0.1
- **WHEN** the registry processes the update
- **THEN** no tombstone is created
- **AND** both sr:AAA and sr:BBB remain canonical devices

### Requirement: IP can be cleared without tombstoning

The system SHALL support clearing a device's IP address (marking it as stale) without tombstoning the device. This allows IP addresses to be reassigned between devices during DHCP churn.

#### Scenario: IP cleared from device with stale IP
- **GIVEN** device sr:AAA has IP=10.0.0.1 but Armis reports a different device now has that IP
- **WHEN** the registry clears sr:AAA's IP
- **THEN** sr:AAA remains a canonical device in inventory
- **AND** sr:AAA's IP field is empty or marked as stale
- **AND** sr:AAA can receive a new IP in a future update
- **AND** the IP=10.0.0.1 is available for assignment to another device
