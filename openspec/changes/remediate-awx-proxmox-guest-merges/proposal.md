# Change: Repair the AWX merges that bound hosts to guests of another cluster

## Why
`fix-awx-proxmox-guest-binding-evidence` stopped AWX inventory hosts from binding to a Proxmox
guest on node name and VMID alone, and stopped a locally administered MAC from corroborating an
AWX match. It changed no data: the records the old rule merged stay merged, and the survivors
keep the MACs the AWX updates copied onto them from the wrong guest. Those survivors hold several
machines' MACs and guest identities, so they keep attracting matches until they are repaired.

Every one of those merges went through `MergeEngine.merge_devices/3` with reason
`awx_proxmox_network_match` or `awx_host_network_match`, so each has a reversible merge audit
row that records what the merged record owned (`source_identifiers`). The repair can therefore
undo exactly the wrong merges, by audit id, instead of reconstructing groupings from current
state. The MAC rows the AWX updates wrote are in no merge audit row and need their own rule.

## What Changes
- A new explicit-only DIRE remediation step, `awx-proxmox-unmerge`, dry run by default, with its
  execute refused unless the release runtime configuration sets
  `enable_awx_proxmox_unmerge_execute`. It is never part of the default run, and it computes its
  plan when it runs: the set grows until the repair runs.
- The step undoes an AWX merge only when its evidence proves the two records are different
  machines: different AWX v2 host ids of one controller, Proxmox guest identities (cluster and
  VMID) that differ, or a merge corroborated only by locally administered MACs. A shared AWX
  host id, guest identity or universally administered MAC voids the proof.
- A bad merge poisons its survivor with the merged record's identifiers, the bound guest's NIC
  MACs and addresses, and the merged record's address. The survivors kept absorbing correct
  records through other merge reasons (`hypervisor_guest_network_match`,
  `identifier_backfill`, ...) after the fix shipped. Every later merge touching a poisoned record,
  of any reason, is judged in time order and is bad when it joins a second Proxmox guest identity
  to a record that had established another, or when everything its match rested on is foreign to
  the poisoned record. Anything else is reported and left in place.
- The bad merges that share records form a unit, undone newest first in one transaction after
  locking every record and planning the unit again; a refusal anywhere rolls the unit back, and
  a unit with any merge that cannot be undone is reported whole.
- Each unmerged pair is recorded as distinct, so no automatic merge path joins it again after
  the one-day merge cooldown that the unmerge audit row arms.
- After the unmerges, a MAC row an AWX update copied from the wrong guest moves to the record
  that holds the guest's identity, or, when no live record does, is archived
  (`device_identifier_archive`, reason `awx_wrong_guest_mac`); both are re-queried. Any row whose
  provenance cannot prove it is reported and kept.
- `source-id-rollback` reverses the step from its manifest: it returns the moved and archived MAC
  rows and merges each pair again, administratively, after removing the distinct assertion.
- A read-only step, `awx-proxmox-verify` (checks A1-A5), shows after the repair and after later
  syncs that the unmerged pairs stayed apart and that no bad merge is still in place.
- `docs/awx-proxmox-unmerge-runbook.md` gives the dry run, execute, verification and rollback
  invocations for a release pod.
- No merge guard changes here; the guard between records with distinct Proxmox guest identities
  is a separate change.

## Impact
- Affected specs: device-identity-reconciliation
- Affected code: `ServiceRadar.Inventory.Remediation.{AwxProxmoxUnmerge, AwxProxmoxVerification,
  Decisions, DireRemediation, SourceIdRollback}`, `Mix.Tasks.Serviceradar.DireRemediation`,
  `ServiceRadar.Inventory.Identity.SourceRetirement.archive_identifiers/4` (archive reason
  argument)
- Follows `fix-awx-proxmox-guest-binding-evidence` (task 2.1), which closed the path that created
  the data. Run only on a release that carries that change on every core pod.
