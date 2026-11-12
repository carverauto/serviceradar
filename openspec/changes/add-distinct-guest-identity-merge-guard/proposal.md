# Change: Refuse automatic merges of records that hold different hypervisor guests

## Why
`fix-awx-proxmox-guest-binding-evidence` stopped AWX hosts from binding to Proxmox guests on a
node name and VMID. Records the old rule had already merged kept several guests' MACs, addresses
and v3 guest references. Those records went on absorbing correct guest records through other
merge reasons, because no guard refused two records that each name a different guest:

- `hypervisor_guest_network_match` merged guests with different VMIDs of one cluster into a record
  that held other guests' v3 references, on MACs and an address it held only because of the
  earlier merges.
- `identifier_backfill`, the scheduled reconciliation, merged a guest record holding its own v3
  reference into such a record over a shared MAC.

The guards that exist compare agents (`distinct_agent_identity`), source-authoritative Armis and
NetBox ids (`source_authority_conflict`) and MAC classes. None compares guest identities, and an
`integration_id` is not source-authoritative.

## What Changes
- A new guard, `distinct_guest_identity`, in `MergeEngine.merge_devices/3`, the function every
  automatic merge goes through. It refuses a merge when, for one generation of guest identity,
  both records hold guest identities and neither record's set contains the other's. Every merge
  reason is covered, present and future; reasons starting with `manual` and `unmerge` bypass it
  as they bypass every guard.
- A guest identity is a live `integration_id` naming a hypervisor guest. Today that is a Proxmox
  v3 guest reference (`proxmox:v3:<integration>:<controller>:<cluster>:<qemu|lxc>:<vmid>`) and a
  legacy v2 guest reference (`proxmox:v2:<cluster>:<vm|lxc>:<vmid>`). v2 and v3 are compared only
  within their generation. Node and cluster references are not guest identities. A retired
  (archived) reference does not count.
- A refused merge is logged at info level, emitted as `guard_blocked` telemetry and recorded as a
  `guard_block` identity decision whose evidence carries both records' guest identities. The
  scheduled reconciliation fingerprints the refusal and skips the unchanged pair; the
  reconciliation rule version is bumped so every blocked pair is evaluated once under the new
  rule.
- No data repair. Records already merged stay merged; a separate remediation splits them.

## Impact
- Affected specs: device-identity-reconciliation
- Affected code: `ServiceRadar.Inventory.Identity.GuestIdentityGuard` (new),
  `ServiceRadar.Inventory.Identity.MergeEngine`, `ServiceRadar.Inventory.Identity.BlockFingerprint`
- Two live records of different guests that an operator knows are one machine merge only through
  a manual merge.
- Related: `fix-awx-proxmox-guest-binding-evidence`, which closed the AWX binding that created
  the records this guard stops from growing.
