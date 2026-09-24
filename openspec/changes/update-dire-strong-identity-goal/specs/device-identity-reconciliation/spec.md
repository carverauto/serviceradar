## ADDED Requirements

### Requirement: Address Is Evidence, Not Identity
The system SHALL NOT use an IP address, or a confirmed IP alias, as a device's identity: an address change SHALL NOT create a device record for a device that holds a strong identifier, and address evidence SHALL NOT merge two device records.
An address-only sighting attaches to the device that currently holds that address. DHCP moves
addresses between devices, so "same address" never implies "same device".

#### Scenario: A known device changes address
- **GIVEN** a device identified by a strong identifier at address A
- **WHEN** an update carrying the same strong identifier arrives from address B
- **THEN** the update SHALL resolve to the existing device
- **AND** no new device record SHALL be created

#### Scenario: An address moves to a different device
- **GIVEN** device X held address A and has since moved to another address
- **AND** device Y, holding a different strong identifier, is now assigned address A
- **WHEN** updates for both devices are processed
- **THEN** devices X and Y SHALL remain separate records

#### Scenario: An address-only sighting attaches without merging
- **GIVEN** a live device currently holds address A
- **WHEN** a sighting with address A and no strong identifier arrives
- **THEN** the sighting SHALL attach to that device
- **AND** no device SHALL be created or merged because of it

### Requirement: Source-Authoritative Identifiers Govern Identity
The system SHALL treat a source-authoritative identifier (for example an Armis device id or a scoped `integration_id`) as governing a record's identity: two records holding different values of the same source-authoritative identifier type SHALL NOT be merged, whatever MAC or address evidence they share.
When such a record reports a MAC or address that a different device holds, the
source-authoritative identifier decides the record's identity, and the MAC or address is
evidence only.

#### Scenario: Different Armis ids with a shared MAC stay separate
- **GIVEN** device X holds Armis device id 1 and device Y holds Armis device id 2
- **WHEN** an update for device Y reports a MAC that device X holds
- **THEN** devices X and Y SHALL NOT be merged
- **AND** the conflict SHALL be recorded as an identity decision

### Requirement: One Live Owner Per Strong Identifier
The system SHALL ensure that each strong identifier, within its partition, is held by at most one live device record.

#### Scenario: A strong identifier is claimed by a second record
- **GIVEN** a live device holds a strong identifier
- **WHEN** another record reports the same identifier
- **THEN** that record SHALL resolve to, or converge with, the device holding it
- **AND** the identifier SHALL NOT be held by two live records

### Requirement: Interface Identifiers Belong To Their Device
The system SHALL register the MAC addresses of a device's own interfaces as dependent identifiers of that device: each SHALL resolve to the device, and none SHALL create a device record of its own.

#### Scenario: A router with many interfaces stays one device
- **GIVEN** a router reports interfaces with MACs M1, M2 and M3
- **WHEN** DIRE registers the interface identifiers
- **THEN** M1, M2 and M3 SHALL all resolve to the router
- **AND** no device record SHALL be created for any single interface

### Requirement: Randomized MACs Are Evidence Only
The system SHALL NOT merge two device records on locally-administered (randomized) MAC addresses, alone or together with other evidence-class identifiers.
A device identified only by evidence-class identifiers is ephemeral. Expiring it is covered by
#4603, and such expiry SHALL NOT remove a device holding a hardware or source-authoritative
identifier.

#### Scenario: Two devices share a randomized MAC
- **GIVEN** two device records that share only a locally-administered MAC
- **WHEN** DIRE processes updates for both
- **THEN** the records SHALL NOT be merged

### Requirement: Duplicates Converge And Stay Converged
The system SHALL converge device records that share a hardware or source-authoritative identifier into one canonical record, and SHALL NOT let an automatic path bring a merged-away record back.
A merged-away device id resolves to its survivor for as long as anything may still present it,
including after its tombstone row is purged. Only an administrative unmerge brings it back, and
the unmerge restores exactly the identifiers the record held when it was merged. A device
deleted for any other reason resolves to itself and is never redirected through an old merge
row.

#### Scenario: A merged-away id is presented again
- **GIVEN** device F was merged into device T
- **WHEN** an ingest, sweep, gateway or agent path later presents device F's id
- **THEN** the id SHALL resolve to device T
- **AND** device F SHALL NOT become live again

#### Scenario: A purged merged-away id is presented again
- **GIVEN** device F was merged into device T and F's tombstone was purged after retention
- **WHEN** a source presents device F's id
- **THEN** the id SHALL resolve to device T
- **AND** no device record with F's id SHALL be created

#### Scenario: Unmerge restores exactly the source's identifiers
- **GIVEN** device F held identifiers S when it was merged into device T
- **WHEN** an administrator unmerges F
- **THEN** exactly the identifiers in S that T still holds SHALL move back to F
- **AND** T SHALL keep every identifier it held that is not in S

#### Scenario: An unrelated deletion does not follow an old merge
- **GIVEN** device F was merged into T and later unmerged
- **WHEN** device F is deleted for a reason other than a merge
- **THEN** F's id SHALL resolve to F itself

### Requirement: Identity Decisions Are Never Silent
The system SHALL record every identity decision that blocks a merge, declines one, or overrides conflicting evidence where an operator can review it, and SHALL NOT make such a decision observable only through logs or telemetry.
The operator workflow for reviewing and acting on these records is #4604.

#### Scenario: A source-authoritative override is recorded
- **GIVEN** a record with a source-authoritative identifier reports a MAC another device holds
- **WHEN** DIRE keeps the records separate
- **THEN** an identity decision record SHALL be written naming both devices and the evidence
