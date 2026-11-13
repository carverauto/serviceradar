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
to the poisoned record and none is that record's own; a shared universally administered MAC
or AWX host id with the survivor's own identity, or a guest identity the survivor has established
(its own, or brought by a merge that stays), SHALL void that proof, except that a NIC MAC of a
guest the merge names or the merged record holds does not count on the side without that guest's
identity. Any other merge on a poisoned record SHALL be reported and left in place.

What a merge put on a record SHALL apply to a later merge only while every merge it came through
is in place at that later merge's time: from the time an unmerge of one of them is recorded, the
poison it brought SHALL no longer apply. The verdict of a merge SHALL therefore depend only on the
history up to that merge.

The repair SHALL be dry run by default, SHALL compute its plan when it runs, and SHALL refuse to
execute unless the release runtime configuration enables it. Bad merges that share records SHALL
form a unit that is undone newest first, by merge audit id, in one transaction after locking its
records and planning the unit again; a merge whose survivor a later merge took away SHALL wait
for that merge. When any merge of a unit cannot be undone, the whole unit SHALL be reported and
none of it undone. Each unmerged pair SHALL be recorded as distinct. Every planned unit SHALL end
in exactly one reported outcome (applied, skipped with its reason, failed, or not run after a
halt); a unit planned differently under its locks SHALL be skipped with each of its merges'
disposition now and logged, and outcomes that do not add up to the planned units SHALL fail the
run.

After the unmerges, the repair SHALL act on a MAC identifier row only when its provenance proves
that it came from the wrong guest: the value is a universally administered NIC MAC of the guest,
the record holding it is proved not to be that guest, the row was last written by an AWX update or
by the guest's own Proxmox report, and neither the record's interfaces, its AWX host's own
inventory variables nor a merge still in place account for it. Such a row SHALL go to the one
live record that holds the guest's identity, or, when there is none and an AWX update wrote it
last, to the identifier archive. Any other such row SHALL be reported and kept. Every row acted on
SHALL be re-queried. Every action SHALL be
written to a rollback manifest before it commits, and the rollback SHALL reverse them.

A merge of any other reason made after the repair unmerged a pair, that joins a record of that pair
to another record, SHALL be judged on the merged record's AWX host: the AWX id it held, or, when it
held none, the AWX host its own `awx` metadata named at the merge (as the merge audit row recorded
the metadata the merge dropped). The merge SHALL be bad, with proof `different_awx_hosts`, when the
survivor held an AWX host id of that controller and not that one, unless the two records shared a
guest identity or a universally administered MAC; otherwise it SHALL NOT be judged. A record the
repair restored can still carry projections of the machine it was joined with, so the repair and
A2/A3 SHALL see such a merge.

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

#### Scenario: A correct merge after the repair is not judged on undone poison
- **GIVEN** a bad merge into a guest's record that has been undone, and a later merge that joins another record of the same machine to that record on an identifier the undone merge had brought
- **WHEN** the repair plans, or `awx-proxmox-verify` runs
- **THEN** the later merge SHALL NOT be judged bad
- **AND** a merge proved bad after the repair SHALL still fail A2 and A3

#### Scenario: A merge onto a record holding the same guest
- **GIVEN** a poisoned record that holds a Proxmox guest's identity through a merge that stays, and a later merge that joins a record of that same guest to it on evidence the poison brought
- **WHEN** the repair plans
- **THEN** the later merge SHALL be reported as `conflicting_evidence` and left in place

#### Scenario: A unit planned differently under its locks
- **GIVEN** two planned units, and a write that lands after the first unit is undone and changes the second unit's verdict
- **WHEN** the second unit is planned again under its locks
- **THEN** the second unit SHALL be rolled back, counted as skipped with reason `disposition_changed` and each merge's new disposition, and logged
- **AND** the applied, skipped, failed and not-run units SHALL add up to the planned units

#### Scenario: A wrong-guest MAC without AWX provenance is kept
- **GIVEN** a record proved not to be the bound guest, holding a MAC of that guest last written by another source
- **WHEN** the repair cleans MAC identifiers
- **THEN** the row SHALL be kept and reported

#### Scenario: A record the repair restored is merged into another machine after the repair
- **GIVEN** a record the repair restored, holding no AWX identifier row, whose own AWX metadata names AWX host 2 of a controller
- **WHEN** after the repair a merge of another reason joins it to a record holding AWX host 1 of that controller
- **THEN** the repair SHALL judge that merge bad with proof `different_awx_hosts` and plan its unmerge
- **AND** `awx-proxmox-verify` SHALL fail A2 and A3 on it
- **AND** a merge after the repair that joins it to the record holding AWX host 2 SHALL NOT be judged

### Requirement: Hypervisor Guest Matching Rests On Identifier Rows
The system SHALL let Proxmox enrichment match an existing record to a guest, and merge it into the guest's device, only on the record's identifier rows, its current address, and an AWX host claim the record backs with that AWX host's identifier row.
A record's display MAC column, the `mac_addresses` list in its metadata and the metadata that
describes a guest binding (`integration_id`, `integration_type` and the `hypervisor_*` keys)
SHALL NOT count as evidence: a merge copies them onto a survivor, enrichment writes them onto
whatever record held a guest's identifier rows at the time, and an unmerge does not move them, so
they can name a machine the record is not. The AWX host claim SHALL be read only from the record's
`awx` metadata and the variables it carries, never from other metadata keys. It SHALL count only
when the record holds an AWX integration id row and, when the claim names its controller and
host, holds that host's id.

#### Scenario: A restored AWX record carrying another guest's MAC in its metadata
- **GIVEN** an AWX host's record that holds no identifier row, whose display MAC and metadata `mac_addresses` name guest G's NIC MAC and whose metadata names guest G's integration id, and whose `awx` metadata declares another VMID
- **WHEN** Proxmox enrichment reports guest G with that NIC MAC
- **THEN** the record SHALL NOT be matched to guest G
- **AND** it SHALL NOT be merged into guest G's device

#### Scenario: An AWX record backing its claim with its own identifier row
- **GIVEN** an AWX host's record holding the host's AWX integration id row, whose `awx` metadata declares guest G's node, VMID and address
- **WHEN** Proxmox enrichment reports guest G with that address
- **THEN** the record SHALL be merged into guest G's device

### Requirement: An Unmerge Leaves Neither Record Describing The Other's Identity
The system SHALL, when it reverses a merge, remove from the restored record every identity projection that names an identifier the survivor holds after the unmerge, and from the survivor every identity projection that names an identifier the merge recorded as the merged record's and the survivor no longer holds.
An identity projection is a value on the device row that repeats an identifier: the display MAC
column, an entry of the metadata `mac_addresses` list, the guest binding metadata
(`integration_id` and `integration_type`, with the `hypervisor_*` keys) when its `integration_id`
or `hypervisor_provider_ref` names the identifier, and the `awx` metadata when the AWX host id it
names is the identifier. An unmerge declares the two records different machines, so a projection
on one naming the other's identifier is false. The restored record is the merge's tombstone, which
keeps whatever was projected onto it while it was itself the survivor of an earlier merge, and a
survivor keeps what enrichment and sync wrote onto it because it held the merged record's
identifiers.

Nothing else SHALL change: other metadata, and a MAC or id neither record's identifiers name,
stay. The unmerge audit row SHALL record every value removed (`dropped_projections`).

#### Scenario: The survivor of an undone merge forgets the merged guest
- **GIVEN** a record that absorbed guest G's record, after which enrichment wrote guest G's integration id, `hypervisor_*` keys and NIC MAC onto it
- **WHEN** the merge is reversed, and guest G's identifier rows are no longer on the survivor
- **THEN** the survivor SHALL no longer show guest G's MAC as its display MAC or in `mac_addresses`
- **AND** its metadata SHALL no longer name guest G's integration id or carry the `hypervisor_*` keys
- **AND** the unmerge audit row SHALL record the removed values

#### Scenario: A restored record does not repeat the survivor's MAC
- **GIVEN** a merged record whose tombstone shows, as its display MAC, a MAC whose identifier row the survivor holds
- **WHEN** the merge is reversed
- **THEN** the restored record's display MAC SHALL be cleared

#### Scenario: A MAC no identifier names is kept
- **GIVEN** a merged record whose display MAC no identifier row of either record holds
- **WHEN** the merge is reversed
- **THEN** the restored record SHALL keep its display MAC
