## ADDED Requirements

### Requirement: AWX Guest-Binding Merges Are Repaired From The Merge Audit
The system SHALL provide an operator-invoked repair that undoes AWX merges (reasons `awx_proxmox_network_match` and `awx_host_network_match`) only when the merge audit and the two records' own identifiers prove the merge joined different machines.
The proof SHALL be one of: AWX v2 host ids of one controller that differ between the two
records, Proxmox guest identities whose cluster or VMID differ between the two records, or a
merge corroborated by a MAC when every MAC the corroborating record held was locally
administered. A shared AWX host id, guest identity or universally administered MAC SHALL void the
proof, and a merge without a proof SHALL be reported and left in place. A NIC MAC of the guest the
merge bound SHALL NOT count as shared on the side that does not hold that guest's identity,
because there it is the AWX update's copy.

A bad merge SHALL poison its survivor with the identifiers the merge recorded for the merged
record, the NIC MACs and addresses of the guest the merge named (unless the survivor holds that
guest's identity) and the merged record's address. A later merge of any reason that touches a
poisoned record SHALL be bad when the merged record holds a Proxmox guest identity and the
survivor had established a different one, or when every identifier its match rested on is foreign
to the poisoned record and none is that record's own; a shared universally administered MAC,
guest identity or AWX host id with the survivor's own identity SHALL void that proof, except
that a NIC MAC of a guest the merge names or the merged record holds does not count on the side
without that guest's identity. Any other merge on a poisoned record SHALL be reported and left in
place.

The repair SHALL be dry run by default, SHALL compute its plan when it runs, and SHALL refuse to
execute unless the release runtime configuration enables it. Bad merges that share records SHALL
form a unit that is undone newest first, by merge audit id, in one transaction after locking its
records and planning the unit again; a merge whose survivor a later merge took away SHALL wait
for that merge. When any merge of a unit cannot be undone, the whole unit SHALL be reported and
none of it undone. Each unmerged pair SHALL be recorded as distinct.

After the unmerges, the repair SHALL act on a MAC identifier row only when its provenance proves
that it came from the wrong guest: the value is a universally administered NIC MAC of the guest,
the record holding it is proved not to be that guest, the row was last written by an AWX update or
by the guest's own Proxmox report, and neither the record's interfaces, its AWX host's own
inventory variables nor a merge still in place account for it. Such a row SHALL go to the one
live record that holds the guest's identity, or, when there is none and an AWX update wrote it
last, to the identifier archive. Any other such row SHALL be reported and kept. Every row acted on
SHALL be re-queried. Every action SHALL be
written to a rollback manifest before it commits, and the rollback SHALL reverse them.

#### Scenario: A merge with a guest of another cluster is undone
- **GIVEN** an AWX merge whose merged record holds the guest identity of cluster A, VMID 101, and whose survivor holds the guest identity of cluster B, VMID 101
- **WHEN** an operator executes the repair with its runtime gate enabled
- **THEN** the merge SHALL be undone by its merge audit id
- **AND** the pair SHALL be recorded as distinct

#### Scenario: An ambiguous merge is reported
- **GIVEN** an AWX merge whose two records hold no AWX host id, guest identity or MAC that proves them different machines
- **WHEN** an operator executes the repair
- **THEN** the merge SHALL stay in place
- **AND** the report SHALL list it with the reason no proof was found

#### Scenario: A chain blocked by a non-qualifying merge
- **GIVEN** an AWX merge of A into B that qualifies, and a later merge of B into C that proves nothing wrong
- **WHEN** an operator executes the repair
- **THEN** neither merge SHALL be undone
- **AND** the report SHALL list the merge of A into B as blocked by the merge of B into C

#### Scenario: A merge of another reason rested on what a bad merge brought
- **GIVEN** a bad AWX merge that left a guest's NIC MAC on its survivor, and a later `hypervisor_guest_network_match` merge of that guest's own record into the survivor on that MAC
- **WHEN** an operator executes the repair
- **THEN** both merges SHALL be undone in one transaction, the later one first
- **AND** the guest's record SHALL hold its own identity and MAC again

#### Scenario: A second guest identity on one record
- **GIVEN** a poisoned record that took in the record of one Proxmox guest by a merge that stays, and later the record of a guest with a different VMID
- **WHEN** the repair plans
- **THEN** the later merge SHALL be bad
- **AND** the first SHALL be reported for review and left in place

#### Scenario: A wrong-guest MAC without AWX provenance is kept
- **GIVEN** a record proved not to be the bound guest, holding a MAC of that guest last written by another source
- **WHEN** the repair cleans MAC identifiers
- **THEN** the row SHALL be kept and reported
