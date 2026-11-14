## ADDED Requirements

### Requirement: A Device Record Never Gains A Second Live Hypervisor Guest
The system SHALL NOT give a live device record a Proxmox v3 guest reference it does not hold when the record would then hold more than one live v3 guest reference, whether at resolution, at identifier registration or in an automatic merge.
A v3 guest reference is a live `integration_id` row of the form
`proxmox:v3:<integration>:<controller>:<cluster>:<qemu|lxc>:<vmid>`. Two references that differ in
any component name two guests, whether one integration or two reported them. A reference retired
to the identifier archive SHALL NOT count. No address, address range, subnet, cluster name,
hostname or observation age SHALL decide whether a held reference counts.

Resolution: an update carrying a v3 guest reference SHALL NOT resolve onto a record that holds a
different live v3 guest reference, whatever identifier, device-id hint, merge redirect or earlier
update of the same batch chose that record. The update SHALL resolve to the guest's own record: a
uid derived from its own identifiers that is neither tombstoned, merged away nor holding another
guest. The refusal SHALL be recorded as a `guard_block` identity decision with reason
`distinct_guest_identity` naming both records and both sets of references, and emitted as
telemetry. An identifier the other record holds SHALL stay on that record.

Registration: a v3 guest reference SHALL NOT be registered on a record that holds a different
live v3 guest reference; the refused row SHALL be dropped, logged at error level and emitted as
telemetry, and the other rows of the registration SHALL be written.

Merge: the `distinct_guest_identity` merge guard SHALL also refuse a merge that would give its
survivor a v3 guest reference it does not hold when the survivor would then hold more than one. A
merge whose reason starts with `manual`, and an unmerge, SHALL NOT be refused by this rule.

#### Scenario: A guest whose MAC another guest's record holds gets its own record
- **GIVEN** a live record holding the v3 reference of guest 101 of one integration and, from an older bad merge, the MAC of guest 101 of a second integration
- **WHEN** the second integration's sync sends its guest 101 with that MAC and its own v3 reference
- **THEN** the update SHALL resolve to a record of its own that holds the second integration's reference
- **AND** the first record SHALL still hold only its own guest reference and keep the MAC row
- **AND** a `guard_block` decision `distinct_guest_identity` SHALL name both records

#### Scenario: Two guests of one integration stay apart
- **GIVEN** a live record holding the v3 reference of container 106 and the MAC of container 107 of the same integration
- **WHEN** a sync sends container 107 with that MAC
- **THEN** container 107 SHALL resolve to a record of its own

#### Scenario: A device-id hint does not override the rule
- **GIVEN** a live record holding the v3 reference of guest 101
- **WHEN** an update carrying guest 102's v3 reference names that record as its device id
- **THEN** the update SHALL resolve to guest 102's own record

#### Scenario: The same guest seen again resolves to its record
- **GIVEN** a live record holding the v3 reference of guest 101
- **WHEN** a sync sends guest 101 again, with a new address or MAC
- **THEN** the update SHALL resolve to that record

#### Scenario: A record that holds a guest's MAC but no guest takes the guest
- **GIVEN** a live record holding a MAC and no v3 guest reference
- **WHEN** a sync sends a guest with that MAC
- **THEN** the update SHALL resolve to that record and register the guest's reference on it

#### Scenario: Registration outside resolution is refused
- **GIVEN** a live record holding the v3 reference of guest 101
- **WHEN** a writer registers guest 102's v3 reference on that record together with a MAC
- **THEN** the guest reference SHALL NOT be registered and the refusal SHALL be logged at error level
- **AND** the MAC SHALL be registered

#### Scenario: A merge does not give the survivor another guest
- **GIVEN** a record holding the v3 references of guests 101 and 102, and a record holding only guest 101's
- **WHEN** an automatic merge of the first into the second is attempted
- **THEN** the merge SHALL be refused with guard `distinct_guest_identity`
- **AND** a merge of the second into the first SHALL NOT be refused by this rule

#### Scenario: A retired reference does not block a new guest
- **GIVEN** a record whose only v3 guest reference was retired to the identifier archive
- **WHEN** a sync sends a guest with a MAC the record holds
- **THEN** the update SHALL resolve to that record

### Requirement: Records Holding Several Hypervisor Guests Are Split On Request
The system SHALL provide an operator-invoked repair, dry run by default and refused in execute mode unless the release runtime configuration enables it, that splits each live record holding more than one live v3 guest reference into one record per guest.
The repair SHALL compute its plan when it runs. For each record it SHALL choose the guest that
keeps the record: the one guest that the record's linked agents and linked AWX memberships are
proven to belong to, or, without such a binding, the guest whose reference the record registered
first. When the bindings point to more than one guest, the record SHALL be reported and left whole.

A MAC row SHALL be proven to a guest only when that guest's hypervisor-reported NICs carry the value
and no other guest of the record's does. An AWX host row, an agent and an AWX membership SHALL be
proven to a guest only when the address they declare is reported on the NICs of exactly one of
the record's guests. Any other identifier SHALL stay on the record and be reported as unproven.

For every other guest the repair SHALL create a record, move the guest's reference and the rows
proven to that guest to it, record every pair of the resulting records as distinct, and change the
identity revision of every record involved. Each record SHALL be split in one transaction after
locking it and planning it again on the locked state; a record whose plan changed SHALL be skipped
with its reason. Every planned record SHALL end in exactly one reported outcome (applied, skipped
with its reason, failed, or not run after a halt), and outcomes that do not add up to the planned
records SHALL fail the run. Every action SHALL be written to a rollback manifest before it commits,
and the rollback SHALL reverse it by merging each new record back into its original record after
removing the distinct assertions the repair created.

A read-only check SHALL list every live record holding more than one live v3 guest reference.

#### Scenario: A record of two clusters' guests is split along a linked AWX host
- **GIVEN** a record holding the v3 references of guest 102 of one integration and guest 104 of another, each guest's NIC MAC, and two AWX host rows whose memberships declare one address of each guest, one of them linked to the record
- **WHEN** the repair executes
- **THEN** the record SHALL keep the guest of the linked AWX host, with its MAC and AWX host row
- **AND** a new record SHALL hold the other guest's reference, its MAC and its AWX host row
- **AND** the two records SHALL be asserted distinct
- **AND** the check SHALL list neither record

#### Scenario: Two guests of one integration are split
- **GIVEN** a record holding the v3 references of containers 106 and 107 of one integration and each container's MACs
- **WHEN** the repair executes
- **THEN** each container SHALL end on its own record with its own MACs

#### Scenario: An identifier no guest can be proven to own stays and is reported
- **GIVEN** a record holding two guests' references and a MAC that both guests' NICs report
- **WHEN** the repair runs
- **THEN** the MAC SHALL stay on the record and be reported as unproven

#### Scenario: Conflicting bindings leave the record whole
- **GIVEN** a record holding two guests' references, linked to an agent whose address one guest reports and to an AWX membership whose address the other guest reports
- **WHEN** the repair runs
- **THEN** the record SHALL be reported `ambiguous_keeper` and SHALL NOT be split

#### Scenario: The dry run changes nothing and execute is gated
- **WHEN** the repair runs without execute mode, or in execute mode without the runtime gate
- **THEN** no record SHALL change and the plan SHALL be reported

#### Scenario: The split is rolled back
- **GIVEN** a manifest of an executed split
- **WHEN** the rollback runs with that manifest
- **THEN** each new record SHALL be merged back into its original record and the distinct assertions the repair created SHALL be removed
