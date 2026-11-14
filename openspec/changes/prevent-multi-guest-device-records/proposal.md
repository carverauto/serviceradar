# Change: A device record never holds two live hypervisor guests

## Why
Deployments that monitor two Proxmox clusters, each its own integration, where the clusters
reuse cluster names, node names, VMIDs and hostnames, have live device records that hold the v3
guest references of two different guests. Every sync of either cluster refreshes the same record,
so its address, MAC and metadata flip between the two machines. A record of two guests of one
integration (two containers with the same hostname) shows the same symptom.

The records got there at ingest, not through a merge:

1. An older bad merge left a record holding the NIC MACs of two guests.
2. Each cluster's first v3 sync sent its guest as an update carrying the guest's new v3 reference
   and its MAC. Hypervisor enrichment's guest-candidate rule refused the record (it already held
   another guest's reference), so the update reached `SyncIngestor` without a device. There
   `BatchResolver.strong_match/2` found no device for the new reference and matched the record on
   the guest's MAC. Nothing compares guest identities at resolution, and an `integration_id` is
   not source-authoritative, so the update resolved onto the record.
3. `IdentifierRecords.bulk_upsert_identifiers/1` registered the new reference on that record:
   identifier attach runs no guard. From then on each sync finds the record by the guest's own
   reference, in `BatchResolver` and in hypervisor enrichment's identity map, and the
   contamination keeps itself alive across identifier generations.

The guards that exist did not apply:

- `distinct_guest_identity` (`add-distinct-guest-identity-merge-guard`) runs only inside
  `MergeEngine.merge_devices/3`. Resolution attaches identifiers without a merge, and that change
  left the resolution side out (its design D6). Its subset rule also lets a record holding guests
  A and B merge into a record holding only A, so the survivor gains B.
- `AliasGuard.distinct_strong_identity_conflict?/3` compares two records' agent ids and MAC sets
  for alias and address merges. The attach is a resolution by a MAC the record shares, so the
  sets are not disjoint, and the guard is not consulted there.
- The chimera check in the agent-link repair counts Armis ids and MAC cardinality to decide where
  an agent links. It never reads guest references and never runs at ingest.
- Distinct assertions written by unmerges refuse merges of their pair of records. The attach
  merges nothing, and the guest's own record did not exist yet.

## What Changes
- New requirement: a device record never gains a second live hypervisor guest. One predicate,
  `GuestIdentityGuard.added_guests/2`, decides it for the three writers that can give a record a
  guest reference:
  - **Resolution** (`BatchResolver`): an update naming a guest never resolves onto a record that
    holds a different live guest, whichever step chose the record (a shared MAC, a device-id hint,
    a merge survivor followed from a tombstone, an earlier update of the same batch). It resolves
    to the guest's own record instead. The refusal is recorded as a `guard_block` decision
    `distinct_guest_identity` and emitted as telemetry.
  - **Identifier attach** (`IdentifierRecords.bulk_upsert_identifiers/1` and
    `Registrar.register_identifiers/3`): a guest reference is not registered on a record that
    holds a different live guest reference. This backstop logs at error level, since resolution
    should have prevented it.
  - **Merge** (`MergeEngine.merge_devices/3`): the `distinct_guest_identity` guard also refuses a
    merge that would give its survivor a v3 guest reference it does not hold when the survivor
    would then hold more than one.
- A new explicit-only DIRE remediation step, `multi-guest-split`, dry run by default, execute
  refused unless the release runtime configuration sets `enable_multi_guest_split_execute`. It
  splits each live record holding several v3 guest references into one record per guest, moving
  each guest's reference and the MAC rows and AWX host rows proven to be that guest's, records
  every pair distinct, writes an NDJSON manifest, and accounts for every planned record.
  `source-id-rollback` reverses it. Identifiers whose owner cannot be proven are reported and left
  where they are.
- A read-only step, `multi-guest-verify`, reports every live record holding more than one live v3
  guest reference.

## Impact
- Affected specs: device-identity-reconciliation
- Affected code: `ServiceRadar.Inventory.Identity.{GuestIdentityGuard, BatchResolver,
  MergeEngine, Registrar}`, `ServiceRadar.Inventory.Sync.IdentifierRecords`,
  `ServiceRadar.Inventory.Remediation.{MultiGuestSplit, MultiGuestVerification, DireRemediation,
  SourceIdRollback}`, `Mix.Tasks.Serviceradar.DireRemediation`
- Builds on `add-distinct-guest-identity-merge-guard` (design D6 left resolution to a later change)
  and `remediate-awx-proxmox-guest-merges` (manifest, distinct assertion and rollback patterns).
- A guest whose MAC an older bad merge left on another record now gets its own record without that
  MAC row (ingest never re-points an identifier); the split moves rows it can prove.
