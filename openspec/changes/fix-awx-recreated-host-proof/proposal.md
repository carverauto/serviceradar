# Proposal: a re-created AWX host is not a distinct host

## Problem

`DireRemediation.run(steps: ["awx-proxmox-verify"])` fails A2/A3 on exactly one
merge on demo, proof only `different_awx_hosts`. It is a CORRECT merge: one VM
(same Proxmox guest ref, same hostname, same inventory) whose AWX host was
re-created. In
`platform.ansible_awx_host_memberships` the old host row is `current=false`,
`expired_at` set, `link_disposition=quarantined`; the new row is `current=true`
at the same `ansible_host`, same controller and inventory.

The planner treats the re-created host id as a different machine, and executing
that unit would split one VM into two records. The `different_awx_hosts` proof
compares recorded identifier values only and never consults membership
liveness, so a superseded row counts as distinct against its own replacement.

## What this changes

The proof evaluation canonicalizes a superseded AWX host id to its current
replacement before the disjoint check: an id naming an expired, non-current
membership row counts as the id naming the current row for the same
controller, inventory and `ansible_host`. Two different current rows, or rows
of different inventories, still prove distinct. No hostname, IP or subnet
heuristics: the link is membership lifecycle only (expired/not-current vs
current), resolved through the same controller, inventory and `ansible_host`
the reconciler itself keys rows by.

Concretely:

1. `AwxProxmoxUnmerge.load_around/2` loads the membership rows for the AWX v2
   ids appearing in the candidate merges, plus the current rows sharing their
   (controller, inventory, `ansible_host`), into `data.awx_memberships`. The
   ids come from the live identifier rows and the merge audit snapshots the
   proof reads (`source_identifiers`, `awx_integration_id`, the dropped AWX
   claim), since source retirement archives the superseded row.
2. `merge_input/2` attaches the snapshot to each merge map, so the pure
   planner (`Decisions.plan_awx_proxmox_unmerge/3`) and both verify checks
   (which share it via `plan/2`) evaluate the same data.
3. `Decisions` canonicalizes superseded ids to their current replacement
   inside `different_awx_hosts?`; without membership data the evaluation is
   byte-identical to today, so existing unit tests keep passing unchanged.

This supersedes the D6 carve-out in `prevent-multi-guest-device-records`
("the planner's treatment of a re-created AWX host ... is unchanged"), which
described that change's scope, not this fix. That file is left alone.

## Impact

- Affected spec: `device-identity-reconciliation` (one MODIFIED requirement
  with a refined proof definition and a new scenario).
- Affected code: `awx_proxmox_unmerge.ex` (load + attach),
  `decisions.ex` (proof evaluation). No schema change, no new queue, no
  execute-path change: Refused/planned units only shrink by the false
  positives.
- Demo: read-only. After the fix, `awx-proxmox-verify` SHALL pass A2/A3 on the
  re-created-host merge and the unfiltered unmerge dry run SHALL plan 0 units
  for it.
