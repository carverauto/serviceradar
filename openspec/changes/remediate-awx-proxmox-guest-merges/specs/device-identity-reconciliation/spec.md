## ADDED Requirements

### Requirement: AWX Guest-Binding Merges Are Repaired From The Merge Audit
The system SHALL provide an operator-invoked repair that undoes AWX merges (reasons `awx_proxmox_network_match` and `awx_host_network_match`) only when the merge audit and the two records' own identifiers prove the merge joined different machines.
The proof SHALL be one of: AWX v2 host ids of one controller that differ between the two
records, Proxmox guest identities whose cluster or VMID differ between the two records, or a
merge corroborated by a MAC when every MAC the corroborating record held was locally
administered. A shared AWX host id, guest identity or universally administered MAC SHALL void the
proof, and a merge without a proof SHALL be reported and left in place.

The repair SHALL be dry run by default and SHALL refuse to execute unless the release runtime
configuration enables it. It SHALL undo merges newest first, by merge audit id, one transaction
per merge, after locking both records and rechecking the plan for that merge. A merge whose
survivor a later merge took away SHALL wait for that merge, and SHALL be reported instead of
undone when that merge does not itself qualify. A later merge onto the survivor of a wrong merge
SHALL NOT be undone on that ground alone. Each unmerged pair SHALL be recorded as distinct.

After the unmerges, the repair SHALL remove a MAC identifier row only when its provenance proves
that an AWX update copied it from the wrong guest: the value is a universally administered NIC MAC
of the guest the merge bound, the record holding it is proved not to be that guest, the row was
last written by an AWX update, and neither the record's interfaces, its AWX host's own inventory
variables nor a merge still in place account for it. Any other such row SHALL be reported and
kept. Removed rows SHALL be moved to the identifier archive and re-queried. Every action SHALL be
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
- **GIVEN** an AWX merge of A into B that qualifies, and a later merge of B into C that does not
- **WHEN** an operator executes the repair
- **THEN** neither merge SHALL be undone
- **AND** the report SHALL list the merge of A into B as blocked by the merge of B into C

#### Scenario: A wrong-guest MAC without AWX provenance is kept
- **GIVEN** a record proved not to be the bound guest, holding a MAC of that guest last written by another source
- **WHEN** the repair cleans MAC identifiers
- **THEN** the row SHALL be kept and reported
