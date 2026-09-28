## ADDED Requirements

### Requirement: Address Is Evidence, Not Identity
The system SHALL NOT use an IP address, or a confirmed IP alias, as a device's identity: an address change SHALL NOT create a device record for a device that holds a strong identifier, and address evidence SHALL NOT merge two device records.
An address-only sighting attaches to the device that currently holds that address. DHCP moves
addresses between devices, so "same address" never implies "same device". Only a record that is
not yet a device may adopt an anchorless provisional seed (a sweep-created row) that holds its
address; an existing device takes the address by the newer-observation rule instead.

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

#### Scenario: An existing device does not adopt a provisional seed
- **GIVEN** an anchorless provisional device, created by a sweep, holds address A
- **AND** a device identified by a strong identifier already exists at another address
- **WHEN** an update for the existing device reports address A
- **THEN** the existing device SHALL take address A, as the newer observation
- **AND** the provisional device SHALL release address A and stay live
- **AND** the existing device SHALL NOT adopt the provisional record
- **AND** an `ip_conflict` identity decision SHALL be recorded

### Requirement: Source-Authoritative Identifiers Govern Identity
The system SHALL treat a source-authoritative identifier (the Armis device id and the NetBox device id) as governing a record's identity: two records holding different values of the same source-authoritative identifier type in one scope SHALL NOT be merged, whatever MAC or address evidence they share.
An `integration_id` is not source-authoritative on its own, because providers do not mint it
stably per device; it never vetoes a match and governs identity only through the typed
provider id it accompanies.
When such a record reports a MAC or address that a different device holds, the
source-authoritative identifier decides the record's identity, and the MAC or address is
evidence only.

#### Scenario: Different Armis ids with a shared MAC stay separate
- **GIVEN** device X holds Armis device id 1 and device Y holds Armis device id 2
- **WHEN** an update for device Y reports a MAC that device X holds
- **THEN** devices X and Y SHALL NOT be merged
- **AND** the conflict SHALL be recorded as an identity decision

#### Scenario: Different NetBox device ids with a shared MAC stay separate
- **GIVEN** device X holds NetBox device id 1 and device Y holds NetBox device id 2
- **WHEN** an update for device Y reports a MAC that device X holds
- **THEN** devices X and Y SHALL NOT be merged
- **AND** the conflict SHALL be recorded as an identity decision

#### Scenario: A changed integration id re-attaches through the device's MAC
- **GIVEN** a device holds integration id G1 and a globally-unique MAC M
- **WHEN** the same source reports integration id G2 with MAC M
- **THEN** the update SHALL resolve to that device

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
The system SHALL NOT merge two device records on locally-administered (randomized) MAC addresses, alone or together with other evidence-class identifiers, and SHALL NOT seed a device uid from one.
An update whose only strong identifier is a MAC is seeded from its first universally
administered MAC, even when a randomized MAC is listed first. An update with no universally
administered MAC is address-only and is named by its address. The one exception is an update
with neither a strong identifier nor an address: it falls back to its MAC, because a random uid
would mint a new record on every sighting. Resolver lookup still matches a randomized MAC that is
already registered to a device, so existing registrations (a hardware sibling's randomized
interface, a virtual machine) keep resolving; registering and merging stay governed by this
requirement.
A device identified only by evidence-class identifiers is ephemeral. Expiring it is covered by
#4603, and such expiry SHALL NOT remove a device holding a hardware or source-authoritative
identifier.

#### Scenario: Two devices share a randomized MAC
- **GIVEN** two device records that share only a locally-administered MAC
- **WHEN** DIRE processes updates for both
- **THEN** the records SHALL NOT be merged

#### Scenario: A randomized MAC seen at two addresses
- **WHEN** sightings carrying the same locally-administered MAC and no other strong identifier
  arrive from addresses A and B
- **THEN** they SHALL resolve to two address-only records named by their addresses
- **AND** no device uid SHALL be seeded from the randomized MAC

#### Scenario: A MAC-only update lists a randomized MAC first
- **GIVEN** an update whose MACs are a locally-administered MAC followed by a universally
  administered MAC, with no other strong identifier
- **WHEN** DIRE names the record
- **THEN** its uid SHALL be seeded from the universally administered MAC

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

### Requirement: Hostname Agreement Is Not Identity
The system SHALL NOT merge two existing devices because their hostnames agree, and SHALL NOT adopt an address holder on hostname agreement when either side holds a source-authoritative identifier.
Hostname agreement at an address may still let a record that is not yet a device adopt the
address holder, when neither side holds a source-authoritative identifier, their hardware
serials and partitions are compatible, and no third device claims either identity. When the
hostnames agree and adoption is refused, the record is written as its own device and the pair is
recorded as a `policy_block` identity decision with reason `hostname_agreement_not_identity`,
which opens a de-duplication task.

#### Scenario: Two existing devices with the same hostname stay separate
- **GIVEN** two live devices whose hostnames agree
- **WHEN** an update for one of them reports the address the other holds
- **THEN** the devices SHALL NOT be merged
- **AND** a `policy_block` identity decision SHALL name both devices

#### Scenario: A source-authoritative holder is not adopted on hostname agreement
- **GIVEN** a device holding an Armis device id at address A
- **WHEN** a NetBox record with the same hostname and address A arrives
- **THEN** the NetBox record SHALL be written as its own device
- **AND** a `policy_block` identity decision SHALL name both devices

### Requirement: Merge Stability and Oscillation Protection
The system SHALL prevent merge oscillation: weak or medium evidence (including confirmed IP aliases) MUST NOT merge two devices that hold distinct strong identities (e.g. different `agent_id` identifiers); a device pair that has merged in either direction within a configurable cooldown window MUST NOT be re-merged automatically (the attempt is blocked, audited, and alerted); merged-away device IDs MUST NOT be recreated by deterministic UID generation or identifier registration (canonical-alias lookup precedes creation).

#### Scenario: IP alias cannot override agent identity
- **GIVEN** device A holds `agent_id` identifier `agent-host02` and device B holds `agent_id` identifier `agent-host01`
- **AND** an IP of device A is recorded as a confirmed alias of device B
- **WHEN** an update for device A is processed
- **THEN** devices A and B are NOT merged
- **AND** the conflicting alias state is flagged for invalidation

#### Scenario: Merge cooldown breaks ping-pong loops
- **GIVEN** devices X and Y were merged within the cooldown window
- **WHEN** a subsequent update would merge them again (in either direction)
- **THEN** the merge is blocked and an oscillation alert is emitted with the pair history

#### Scenario: Tombstoned device is not resurrected
- **GIVEN** device F was merged into device T
- **WHEN** a later update or agent hello produces device F's deterministic UID or one of its former identifiers
- **THEN** resolution returns canonical device T
- **AND** no new device record with F's ID is created

## MODIFIED Requirements

### Requirement: IP Alias Resolution
The system SHALL resolve an address-only device update through a confirmed IP alias before generating a new device ID, and SHALL NOT merge devices because of a confirmed IP alias.
A confirmed alias is address evidence, subordinate to strong identity. When an update identified
by a strong identifier arrives at an address that is a confirmed alias of a different device, the
two devices stay separate: an alias holder that is itself identified has the conflicting alias
invalidated, recorded as an `alias_invalidated` identity decision, and an address-only holder is
left alone.

#### Scenario: Interface-discovered IP alias resolves a sweep host
- **GIVEN** a device `sr:<uuid>` has a confirmed IP alias `192.0.2.98` recorded from interface discovery
- **WHEN** a sweep result arrives with host IP `192.0.2.98` and no strong identifiers
- **THEN** DIRE SHALL resolve the update to the canonical device ID
- **AND** SHALL NOT create a new device record for the alias IP

#### Scenario: A strong-identified update at an identified holder's alias
- **GIVEN** a device update with a strong identifier resolves to device X
- **AND** the update IP is a confirmed alias for device Y, which holds a strong identifier of its own
- **WHEN** DIRE processes the update
- **THEN** devices X and Y SHALL NOT be merged
- **AND** the alias state for that IP on device Y SHALL be invalidated
- **AND** an `alias_invalidated` identity decision SHALL name both devices and the address

#### Scenario: A strong-identified update at an address-only holder's alias
- **GIVEN** a device update with a strong identifier resolves to device X
- **AND** the update IP is a confirmed alias for device Y, which holds no strong identifier
- **WHEN** DIRE processes the update
- **THEN** devices X and Y SHALL NOT be merged
- **AND** the alias state for that IP on device Y SHALL be left unchanged
