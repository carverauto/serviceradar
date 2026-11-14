# Design: a device record never holds two live hypervisor guests

## D1. The invariant and its one predicate
A guest identity here is a Proxmox v3 guest reference,
`proxmox:v3:<integration>:<controller>:<cluster>:<qemu|lxc>:<vmid>`, held as a live
`integration_id` row (`GuestIdentityGuard.guest_identity/1`). Two references that differ in any
component are two guests, whichever integration reported them: two guests of one integration are
as distinct as guests of two clusters.

`GuestIdentityGuard.added_guests(held, incoming)` returns the v3 guest references a record would
gain that make it hold more than one: the references in `incoming` that are not in `held`, when
`held ∪ incoming` has more than one. Empty means the operation is allowed. Every writer below asks
this one function; none keeps its own copy of the rule.

| Writer | `held` | `incoming` | On a non-empty answer |
| --- | --- | --- | --- |
| `BatchResolver` final target | the target record's live references plus those earlier updates of the batch claimed on it | the update's reference | resolve to the guest's own record (D3) |
| `IdentifierRecords.bulk_upsert_identifiers/1`, `Registrar.register_identifiers/3` | the target record's live references plus those earlier rows of the call put on it | the row's reference | drop the row, log at error level, emit telemetry |
| `MergeEngine.merge_devices/3` (`distinct_guest_identity`) | the survivor's live references | the merged record's live references | refuse the merge |

Legacy v2 references are left out of the predicate. They are lookup bridges that are no longer
registered, two clusters with the same name share them, and the alias reconciler decides which v3
guest a v2 value means. The existing merge rule keeps comparing v2 with v2.

## D2. Live, not stale: held means live
A reference counts while it is a row in `device_identifiers`; a row moved to
`device_identifier_archive` does not count. This is the definition the merge guard already uses
(`add-distinct-guest-identity-merge-guard`, D4), so resolution, attach and merge agree on which
records are different guests.

No time window, `last_seen` age or "absent from the latest collection" test decides liveness:

- An integration that stops reporting (credentials expired, controller unreachable, collector
  down) leaves every one of its references as old as a deleted VM's. A time rule would then judge
  all of them stale, let the other cluster's guests attach to those records on a shared MAC, and
  rebuild exactly the records this change repairs once the integration recovers. Judging staleness
  against the same integration's newest observation avoids that, but it needs a per-integration
  collection boundary the hypervisor inventory does not record, and it would rarely matter (D2.1).
- The two errors are not symmetric. Treating a dead reference as live gives a re-created VM its own
  record while the old one ages out; treating a live reference as dead merges two machines, and
  the merged record keeps attracting both. DIRE takes the temporary duplicate.

### D2.1 Migration and re-creation
- A migration between nodes of one cluster keeps the VMID and the cluster, so the reference is
  unchanged and nothing is refused.
- A VM re-created under a new VMID, restored into the other cluster, or reported by a re-added
  integration is a new reference: by Proxmox's own identity a different guest. It gets its own
  record. The old record keeps its old reference until it is retired, deleted or cleaned up, after
  which the records may converge through the ordinary merge paths (the merge guard ignores an
  archived reference). This is the behaviour the merge guard already has for the same records;
  before this change only resolution's MAC match carried history across, and that is the path
  that built the multi-guest records.

## D3. What resolution does instead
The check runs on the final target, after the canonical follow and the re-issue redirect, so it
covers every step that can choose a record: a strong-identifier match on a MAC, hardware serial or
other identifier, the device-id hint hypervisor enrichment passes for a guest it already bound, a
merge survivor followed from a tombstone, the hardware-MAC sibling heal. When the target would gain
a second guest, the update resolves to the uid derived from its own identifiers
(`Ids.generate_deterministic_device_id/1`, seeded by the guest reference), stepped past a uid that
is tombstoned, merged away, unrevivable or itself holding another guest, the same reseeding that
source-authoritative overrides use. The update claims its reference on the uid it resolved to, so
a later update of the same batch naming another guest is refused that record too.

Each refusal is recorded once per pair as a `guard_block` identity decision with reason
`distinct_guest_identity` and source `sync_ingestor`, evidence naming the update's reference and
the target's references, and emitted as
`[:serviceradar, :inventory, :guest_identity, :resolution_refused]`. Once the guest has its own
record, the next sync resolves it by its own reference before any MAC, so the refusal does not
repeat.

The shared MAC row stays on the record that holds it: ingest never re-points an identifier
(`IdentifierRecords.conflict_replace_fields/0`). Moving rows that belong to another guest is the
remediation's job, where ownership can be proven (D5).

## D4. Attach and merge
The attach backstop exists because two writers register guest references without going through
`BatchResolver`: hypervisor enrichment's MAC sync (`sync_existing_device_mac_identities/4`) writes
the guest's reference and MACs onto the record it bound the guest to, and `Registrar` registers
whatever identifiers its caller passes. Hypervisor enrichment already refuses a guest candidate that
holds another hypervisor reference, so the backstop should never fire; when it does it reports a
resolution defect loudly instead of silently building a two-guest record. It drops only the guest
reference row; the rest of the batch lands.

The merge guard's subset rule ("one set contains the other: allowed") stays for its original cases.
What changes is the case it could not see: a merged record holding guests A and B and a survivor
holding A. The survivor would gain B, so the merge is refused, with the same guard name,
telemetry, decision and fingerprint as before. A merged record with two guests and a survivor with
none is refused for the same reason. A survivor that already holds every guest of the merged record
gains nothing and is not refused by this rule. Manual and unmerge reasons bypass it as they bypass
every guard.

## D5. The remediation: `multi-guest-split`
Candidates are live records holding more than one live v3 guest reference. For each candidate the
plan decides which guest keeps the record (the keeper) and, for each other guest, which rows move
to that guest's new record.

### Ownership evidence
Evidence comes from the guests' own hypervisor inventory and from identifiers, never from address
ranges, subnets, cluster names or hostnames:

- **NIC MACs.** `virtualization_network_interfaces` rows of a guest name the MACs the hypervisor
  reports for it. A MAC row of the record is proven to a guest when that guest's NICs report the
  value and no other guest of the record does. A value reported by several of the record's guests
  (a CNI placeholder, a cloned MAC) or by none is ambiguous.
- **Addresses as a pointer, not an identity.** An AWX host row (`awx:v2:<controller>:host:<id>`) is
  proven to a guest when the host's current AWX membership declares an `ansible_host` address that
  exactly one of the record's guests reports on its NICs. The address does not identify anything
  on its own: it only selects among guests the record already holds, and an address two of them
  report, as two clusters reusing one private range do, is ambiguous. The same test points an agent
  linked to the record (`ocsf_agents.device_uid`, not superseded) at its guest by the address the
  agent reports. Legacy name-keyed AWX rows (`awx:host:<name>`) cannot be proven and stay.
- **Everything else stays.** Every row of the record, whatever its type, that is not a guest
  reference and is not proven to a guest by the tests above stays on the record and is listed in
  the plan as unproven. The dry-run report lists every plan the execute would apply.

### Keeper
The record keeps the guest that its operator-facing bindings belong to, so they stay valid:

1. Anchors: each linked agent and each AWX membership linked to the record
   (`canonical_device_uid`) whose host is proven to a guest names that guest.
2. When the anchors name exactly one guest, it is the keeper. When they name several, the record is
   reported `ambiguous_keeper` and left whole: splitting it would move a binding to the wrong
   machine.
3. With no anchor, the keeper is the guest whose reference was registered on the record first
   (earliest `first_seen`, then the reference itself). Every other guest gets its own record either
   way, so this choice only decides which guest keeps the uid and its history.

### Execute
One transaction per candidate. It locks the record, plans the candidate again on the state under
the lock and refuses (`plan_changed`) when the plan differs, creates one record per moved guest
(a deterministic uid derived from the record and the reference, reseeded past any existing row, with
the guest's inventory name as hostname, and none when the inventory has no name), reassigns that
guest's reference and proven rows to it
(`DeviceIdentifier :reassign_device`), records every pair of the resulting records distinct
(`Deduplication.assert_distinct/4`), and bumps the identity revision of every record involved so a
concurrent ingest pinned to the old composition is withheld at the identity fence. A synced
preflight manifest entry precedes the transaction, the action entry is written inside it, and a
committed marker follows it. Every planned candidate ends in exactly one outcome: applied, skipped
with its reason, failed, or not run after a halt; outcomes that do not add up fail the run
(`unit_accounting_failures`).

The guest inventory rows (`virtualization_guests.device_uid`, guest NIC `device_uid`) are not
written: the next hypervisor sync binds them to the guest's new record through its reference.

### Rollback and verification
`source-id-rollback` reverses a `guest_split` entry by removing the distinct assertions the step
created and merging each new record back into the original record administratively
(`manual_guest_split_rollback`), which returns every identifier the new record holds. A new record
that was merged elsewhere since, or deleted, is skipped and reported.

`multi-guest-verify` (read-only, refused under execute) lists every live record holding more than
one live v3 guest reference. It passes when the list is empty; run it after the split and after
the next syncs of every Proxmox integration.

## D6. Not in this change
- A MAC row an older bad merge left on another record stays there until the split or an operator
  moves it; ingest still never re-points an identifier.
- AWX membership rows and guest inventory rows are not rewritten by the split (D5).
- The `awx-proxmox-unmerge` planner's treatment of a re-created AWX host (old row expired, new row
  current, same inventory and host name) as `different_awx_hosts` is unchanged.
