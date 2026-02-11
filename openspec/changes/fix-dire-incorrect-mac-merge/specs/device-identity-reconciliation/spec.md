## ADDED Requirements

### Requirement: Polling Agent Exclusion from Interface MAC Registration
The system SHALL NOT include the polling agent's `agent_id` when registering interface MAC addresses discovered via SNMP or other remote polling. The `agent_id` in interface discovery records identifies the agent that performed the poll, not the device that owns the interface, and MUST be excluded from identifier registration for the polled device.

#### Scenario: Agent polls remote device interfaces without false merge
- **GIVEN** agent-dusk (at `192.168.2.22`) SNMP-polls tonka01 (`192.168.10.1`)
- **AND** tonka01 has interface MAC `0e:ea:14:32:d2:78`
- **WHEN** the mapper registers interface identifiers for tonka01
- **THEN** the MAC SHALL be registered as an identifier for tonka01
- **AND** `agent-dusk` SHALL NOT be included in the identifier registration for tonka01
- **AND** the agent-dusk device and tonka01 SHALL remain separate devices

### Requirement: Mapper Device Creation for Unresolved IPs
The system SHALL create a device record through DIRE when the mapper discovers interfaces on a device IP that has no existing device in inventory. The device SHALL receive a proper `sr:` UUID via DIRE and SHALL have `mapper` added to its `discovery_sources`.

#### Scenario: Mapper creates device for SNMP-polled host with no existing record
- **GIVEN** agent-dusk SNMP-polls farm01 at `192.168.2.1`
- **AND** no device exists in `ocsf_devices` with IP `192.168.2.1`
- **WHEN** the mapper processes the interface results
- **THEN** DIRE SHALL generate a deterministic `sr:` UUID for farm01
- **AND** a device record SHALL be created with `ip: 192.168.2.1` and `discovery_sources: ["mapper"]`
- **AND** interface records SHALL be processed and linked to the new device

#### Scenario: Mapper does not duplicate existing device
- **GIVEN** tonka01 already exists in `ocsf_devices` at IP `192.168.10.1`
- **WHEN** the mapper processes interface results for `192.168.10.1`
- **THEN** the existing device SHALL be used
- **AND** no new device SHALL be created

### Requirement: Locally-Administered MAC Classification
The system SHALL classify MAC addresses as globally-unique or locally-administered using the IEEE standard (bit 1 of the first octet). Locally-administered MACs MUST be registered with `medium` confidence and SHALL NOT be used as the sole basis for merging two devices.

#### Scenario: Locally-administered MAC does not trigger merge
- **GIVEN** device A has locally-administered MAC `0EEA1432D278` registered as a medium-confidence identifier
- **AND** device B reports the same MAC from interface discovery
- **WHEN** DIRE processes the interface MAC registration
- **THEN** DIRE SHALL NOT merge device B into device A based solely on a medium-confidence identifier match

#### Scenario: Globally-unique MAC still triggers merge
- **GIVEN** device A has globally-unique MAC `001122334455` (bit 1 of first octet is clear) registered as a strong identifier
- **AND** device B reports the same MAC from interface discovery
- **WHEN** DIRE processes the identifier conflict
- **THEN** DIRE SHALL merge the devices since the MAC is strong-confidence

### Requirement: Hostname Conflict Merge Guard
The system SHALL block an automatic merge when both the source and target devices have different non-empty hostnames, and SHALL log a warning with the conflicting hostnames and triggering identifier.

#### Scenario: Different hostnames block merge
- **GIVEN** device A has hostname `tonka01` and device B has hostname `farm01`
- **AND** they share a MAC address identifier
- **WHEN** DIRE attempts to merge device B into device A
- **THEN** the merge SHALL be blocked
- **AND** a warning log SHALL include both hostnames and the shared identifier

#### Scenario: Empty hostname does not block merge
- **GIVEN** device A has hostname `tonka01` and device B has no hostname
- **AND** they share a strong MAC identifier
- **WHEN** DIRE attempts to merge
- **THEN** the merge SHALL proceed normally

### Requirement: Device Unmerge
The system SHALL provide an administrative `unmerge_device` action that reverses an incorrect merge using the `merge_audit` trail: recreating the from-device, reassigning its original identifiers, and recording an `unmerge_audit` entry.

#### Scenario: Unmerge restores from-device
- **GIVEN** a device was merged into another with a recorded merge_audit entry
- **WHEN** an administrator invokes `unmerge_device` with the from_device_id
- **THEN** the from-device SHALL be recreated in `ocsf_devices`
- **AND** identifiers that originally belonged to the from-device SHALL be reassigned back
- **AND** an `unmerge_audit` entry SHALL be recorded

## MODIFIED Requirements

### Requirement: Interface MAC Registration
The system SHALL register MAC addresses discovered on a device's interfaces as identifiers for that device within the device's partition. The polling agent's identity MUST NOT be included in the identifier registration. Locally-administered MACs (IEEE bit 1 of first octet set) SHALL be registered with `medium` confidence. Globally-unique MACs SHALL be registered with `strong` confidence.

#### Scenario: Interface MACs prevent duplicate devices
- **GIVEN** a mapper or sweep update that includes a list of interface MAC addresses for a device
- **WHEN** DIRE registers identifiers for the device
- **THEN** each globally-unique interface MAC SHALL be inserted into `device_identifiers` with `strong` confidence
- **AND** each locally-administered interface MAC SHALL be inserted with `medium` confidence
- **AND** the polling agent's `agent_id` SHALL NOT be included in the identifier registration
- **AND** subsequent updates that include any strong-confidence MAC SHALL resolve to the same device ID

#### Scenario: Locally-administered interface MACs do not cause false merges
- **GIVEN** two physically distinct devices share a locally-administered MAC from virtual interfaces
- **WHEN** DIRE registers interface identifiers for both devices
- **THEN** both MACs SHALL be registered with `medium` confidence
- **AND** DIRE SHALL NOT merge the two devices based solely on the shared medium-confidence MAC
