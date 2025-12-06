## ADDED Requirements

### Requirement: Batch-level IP Uniqueness Enforcement

The system SHALL enforce IP uniqueness within a single batch of device updates before attempting database insertion, preventing duplicate key constraint violations.

#### Scenario: Two strong-identity devices with same IP in batch
- **WHEN** a batch contains device A (sr:uuid-a, IP=192.168.1.100, armis_id=12345) and device B (sr:uuid-b, IP=192.168.1.100, netbox_id=67890)
- **THEN** the system converts device B to a tombstone pointing to device A
- **AND** merges device B's metadata (including netbox_id) into device A
- **AND** the batch insert succeeds without constraint violation

#### Scenario: Weak-identity device follows strong-identity device with same IP
- **WHEN** a batch contains device A (sr:uuid-a, IP=192.168.1.100, armis_id=12345) followed by device B (sr:uuid-b, IP=192.168.1.100, no strong identity)
- **THEN** the system converts device B to a tombstone pointing to device A
- **AND** the batch insert succeeds

#### Scenario: Tombstone ordering within batch
- **WHEN** a batch contains both canonical devices and tombstones
- **THEN** tombstones are ordered after their canonical targets in the batch
- **AND** this ensures canonical devices exist before references are created

### Requirement: Identity Marker Preservation During Merge

When merging devices due to IP collision, the system SHALL preserve identity markers from the tombstoned device to maintain lookup capability.

#### Scenario: Armis ID preserved during merge
- **WHEN** device B with armis_device_id=12345 is tombstoned into device A
- **THEN** device A's metadata contains armis_device_id=12345
- **AND** the device can still be looked up by that Armis ID

#### Scenario: Multiple identity markers preserved
- **WHEN** device B with netbox_device_id=100 and integration_id=ABC is tombstoned into device A
- **THEN** device A's metadata contains both netbox_device_id=100 and integration_id=ABC

### Requirement: IP Collision Observability

The system SHALL provide visibility into IP collision events within batches.

#### Scenario: IP collision metric recorded
- **WHEN** an IP collision is detected and resolved within a batch
- **THEN** the `device_batch_ip_collisions_total` metric is incremented

#### Scenario: IP collision logged
- **WHEN** an IP collision is detected
- **THEN** a Debug-level log entry records the IP address and both device IDs involved
