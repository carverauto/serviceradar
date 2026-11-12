# Design: distinct guest identity merge guard

## D1. One choke point
Every automatic merge calls `MergeEngine.merge_devices/3`, and its guards run before the merge
transaction. The guard lives there, not in the callers, so `hypervisor_guest_network_match`,
`identifier_backfill`, `identifier_conflict`, the `awx_*` reasons, `ip_alias_conflict`,
`source_succession` and any later reason are covered by one rule.

## D2. Sets, not single values
A record that absorbed other guests holds several guest identities. Comparing one value per
record cannot decide for it, so the guard compares sets: within a generation, two non-empty sets
where neither contains the other prove at least one guest on each side that the other is not.

- Equal sets: the same guest seen again. Allowed.
- One set contains the other: the larger record already names every guest of the smaller one;
  merging adds no guest to it. Allowed. (A record holding guests it should not is a repair
  problem, not something this guard can see.)
- One side empty: an AWX host, an agent's record or a discovered record, which names no guest.
  Allowed.
- Otherwise: refused.

## D3. Which identities count
`IntegrationIdentity` defines guest identities only for Proxmox. A v3 guest reference is the
authoritative identity: the integration and controller UUIDs, the cluster, the kind and the
VMID, and any differing component is a different guest. Its canonical rendering is compared as a
string; `IntegrationIdentity.parse_v3/1` accepts only the canonical form.

A v2 guest reference is cluster-scoped and VMID-keyed, so two different v2 guest references of
one record pair are two guests. A v2 reference names no integration or controller, so it cannot
prove which v3 guest it is: two controllers can share a cluster name and a VMID. The alias
reconciler (`VirtualizationIdentityAliases`) maps legacy references to v3 targets and quarantines
ambiguous ones. The guard therefore compares v2 with v2 and v3 with v3, never across.

Node and cluster references describe hosts and clusters, not guests. Another hypervisor provider
adds a clause to `GuestIdentityGuard.guest_identity/1` once its identity format exists.

## D4. Live identifiers only
An identifier moved to `device_identifier_archive` no longer names the record's guest. A retired
reference does not block the merge that converges its record, including a source succession.
A VM re-created under a new VMID is a different guest while the old guest still exists in the
inventory; once the old reference is gone from the record, the records may converge.

## D5. Recording and repetition
A refusal is recorded like the other guards: `guard_blocked` telemetry, an info log line, and a
`guard_block` identity decision keyed by the pair (an upsert that counts occurrences). The
decision evidence carries the generation and both sets of guest identities.

The scheduled reconciliation fingerprints the pair (`BlockFingerprint`). The fingerprint already
covers every live and archived `integration_id` row of both records, which is everything the
guard reads, so the guard joins the fingerprinted guards and the rule version is bumped. An
ingest path that re-attempts a refused pair (hypervisor enrichment on each result) re-records
the decision as one more occurrence of the same row, as for every other guard.

## D6. Not in this change
- The guard runs before the merge transaction, as the agent and provisional guards do. It is not
  re-checked under the device locks; a guest reference registered on one of the pair between the
  check and the merge is not seen.
- Resolution: an update can still resolve onto a record holding a different guest's reference
  through a MAC or address. That is the ingest-side rule of
  `fix-awx-proxmox-guest-binding-evidence` and of hypervisor enrichment, not a merge.
