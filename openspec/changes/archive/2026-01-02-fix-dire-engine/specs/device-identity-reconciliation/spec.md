## ADDED Requirements

### Requirement: Unified Identity Engine
The system SHALL use a single IdentityEngine as the authoritative source for device identity resolution, consolidating all identity lookup and generation logic into one component with deterministic behavior.

#### Scenario: Strong identifier resolves to existing device
- **WHEN** a device update arrives with an armis_device_id that matches an existing device
- **THEN** the IdentityEngine returns the existing device's sr: UUID without generating a new ID

#### Scenario: New strong identifier generates deterministic UUID
- **WHEN** a device update arrives with a new armis_device_id not seen before
- **THEN** the IdentityEngine generates a deterministic sr: UUID based on the hash of (partition, identifier_type, identifier_value)

#### Scenario: Multiple resolvers removed
- **WHEN** the IdentityEngine is enabled
- **THEN** DeviceIdentityResolver, identityResolver, and cnpgIdentityResolver are no longer used and can be removed

### Requirement: Strong Identifier Index
The system SHALL maintain a device_identifiers table that indexes all strong identifiers (armis_device_id, mac, netbox_device_id, integration_id) with a unique constraint per (identifier_type, identifier_value, partition) to prevent duplicate devices.

#### Scenario: Identifier lookup is O(1)
- **WHEN** the system needs to resolve a strong identifier to a device ID
- **THEN** it queries device_identifiers by (type, value, partition) and receives the result in constant time

#### Scenario: Duplicate identifier rejected
- **WHEN** an attempt is made to insert a device with a strong identifier that already exists for a different device in the same partition
- **THEN** the insert is rejected with a unique constraint violation and the existing device ID is returned instead

### Requirement: IP Churn Detection
The system SHALL detect IP churn (IP reassignment between devices with different strong identifiers) and handle it by clearing the IP from the old device rather than creating tombstones or merging.

#### Scenario: IP churn between strong-ID devices
- **WHEN** a device update (armis_id=Y, IP=10.0.0.1) conflicts with existing device (armis_id=X, IP=10.0.0.1)
- **THEN** the system clears IP from the existing device X, assigns IP to device Y, and does NOT create a tombstone

#### Scenario: IP churn metric emitted
- **WHEN** IP churn is detected between two devices
- **THEN** the ip_churn_events_total metric is incremented with labels for the partition and identifier types

### Requirement: Restricted Tombstone Usage
The system SHALL only create tombstones (_merged_into) for legacy ID migration from partition:IP format to sr: UUID format, and SHALL NOT create tombstones for IP conflicts between devices with different strong identifiers.

#### Scenario: Legacy ID migration creates tombstone
- **WHEN** a device with ID "default:10.0.0.1" is resolved to "sr:abc123"
- **THEN** a tombstone is created pointing default:10.0.0.1 -> sr:abc123

#### Scenario: IP conflict does not create tombstone
- **WHEN** an IP conflict occurs between sr:AAA (armis_id=X) and sr:BBB (armis_id=Y)
- **THEN** no tombstone is created; instead IP is cleared from the old device

#### Scenario: Invalid tombstone rejected
- **WHEN** a tombstone would point to a non-existent, deleted, or already-tombstoned device
- **THEN** the tombstone creation is rejected and a warning is logged

### Requirement: CNPG-Authoritative Device Counts
The system SHALL treat CNPG as the authoritative source for device inventory counts and SHALL sync the in-memory registry from CNPG on startup and periodically.

#### Scenario: Registry syncs from CNPG on startup
- **WHEN** the core service starts
- **THEN** the DeviceRegistry hydrates its in-memory cache from CNPG unified_devices table

#### Scenario: Periodic registry sync
- **WHEN** the configured sync interval elapses (default 5 minutes)
- **THEN** the registry refreshes its cache from CNPG and the registry_cnpg_drift metric is updated

#### Scenario: Drift alert fires
- **WHEN** the difference between registry device count and CNPG device count exceeds 1%
- **THEN** an alert is emitted and the registry_cnpg_drift metric reflects the gap

### Requirement: No Soft Deletes
The system SHALL NOT use soft delete flags (_deleted, deleted) or tombstones (_merged_into). Device updates simply UPDATE existing records, and explicit user deletion performs a hard DELETE with audit logging.

#### Scenario: Device update is just an UPDATE
- **WHEN** a device update arrives for an existing device
- **THEN** the system performs an UPDATE on unified_devices, not a soft delete/recreate cycle

#### Scenario: Explicit deletion is hard DELETE
- **WHEN** a user explicitly deletes a device via UI/API
- **THEN** the system performs a hard DELETE on unified_devices and logs the deletion to device_updates for audit

## MODIFIED Requirements

### Requirement: Strong-ID Merge Under IP Churn
The system SHALL treat strong identifiers (e.g., MAC, Armis ID, NetBox ID) as canonical across IP churn, and SHALL distinguish between true identity matches (merge) and IP reassignment (churn) based on strong identifier comparison rather than IP-based conflict resolution.

#### Scenario: Faker IP shuffle does not inflate inventory
- **WHEN** multiple sightings arrive over time for the same armis_device_id or MAC but with different IPs/hostnames
- **THEN** the reconciliation engine attaches them to the existing canonical device instead of creating new devices, and total device inventory stays within the configured strong-ID baseline tolerance

#### Scenario: Different strong IDs never merge
- **WHEN** two devices with different armis_device_ids temporarily share the same IP due to DHCP churn
- **THEN** the devices remain distinct, IP is reassigned to the newer sighting, and no merge or tombstone occurs
