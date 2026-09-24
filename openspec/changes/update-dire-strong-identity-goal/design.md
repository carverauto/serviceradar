# Design: DIRE identity grounded on strong identifiers

## Goal

One canonical device record per physical device, whatever its address. Identity comes from
strong identifiers. An address is an attribute of a device and evidence about it for a limited
time. It never identifies a device.

## Identifier classes

Identifiers are grouped into classes, following IRE identification rules. A device's identity
is decided by the strongest class it holds.

| Class | Examples | Role |
|---|---|---|
| Source-authoritative | Armis device id, scoped `integration_id`, NetBox id | Governs identity. Two different values are two different devices, whatever other evidence says. |
| Hardware | chassis/hardware serial, globally-unique MAC | Identifies a device where no source-authoritative id exists. It may merge two records. |
| Dependent | interface MACs reported for a device's own interfaces | Resolve to their device. They never create a device and never, on their own, merge two devices that already hold different hardware or source-authoritative ids. |
| Evidence | locally-administered (randomized) MAC, IP address, confirmed IP alias, hostname | Attaches a sighting to a device. Never merges two devices, never overrides a stronger class, and never keeps a device alive by itself. |

## Decisions

### D1. Address is evidence with a lifetime

DHCP moves an address from one device to another, so "same address" can never mean "same
device". An address-only sighting attaches to the device that currently holds that address.
A confirmed IP alias is the same kind of evidence: it can resolve an address-only update. It
cannot merge devices whose strong identities differ, and conflicting alias state is
invalidated rather than acted on. The guarded `IP Alias Resolution` in
`refactor-device-identity-reconciliation` already says this. That change is left to own the
wording, and this design depends on it being archived rather than on a second copy.

### D2. Source-authoritative identifiers win, visibly

When a record with a source-authoritative id reports a MAC or address that a different device
holds, the source-authoritative id decides the record's identity and the MAC or address is
evidence only. The override is recorded as an identity decision (D6), so the rule can be
measured before anyone relies on it.

### D3. Interfaces are dependent

A device with many interfaces (a router, a switch) stays one device. Its interface MACs are
registered as dependent identifiers, and each one resolves to the device. This follows IRE's
dependent-item rule: the network adapter is identified within its parent.

### D4. Randomized MACs never identify

A locally-administered MAC is registered at medium confidence and never, alone or with other
evidence-class identifiers, merges two devices. A device identified only by evidence-class
identifiers is ephemeral. Expiring it on last-seen is #4603. The requirement here is only that
such expiry can never remove a device holding a stronger class.

### D5. Converge, then stay converged

- Two records sharing a hardware or source-authoritative identifier converge to one.
- A merged-away record never comes back through any automatic path.
- Its uid resolves to the survivor for as long as anything may still present it, including
  after the tombstone row is purged. Hence `merge_audit` outlives the purge, and resolution
  follows it for purged uids.
- Only an administrative unmerge brings the record back. The unmerge returns exactly the
  identifiers the record held when it was merged.
- A device deleted for any reason other than a merge resolves to itself. An old merge row,
  for example one an unmerge has since reversed, never redirects it.

### D6. Nothing is silent

Every identity decision that blocks, overrides, or declines a merge is recorded where an
operator can see it, not only in logs or telemetry. This matches IRE's de-duplication task,
and the operator workflow is #4604.

### D7. Revival is an identity transition

Discovery (a sweep, an integration sync, an agent check-in) may restore a device that was
deleted for a reason other than a merge. Every restore, whatever path performs it, increments
`identity_revision` and leaves a `device_revival_audit` row. A path that clears a tombstone
without doing both is a defect.

## Legacy wording this supersedes

| Where | Wording | Resolution |
|---|---|---|
| `device-inventory` "Restore Soft-Deleted Devices" | discovery restores any tombstone | MODIFIED here (D5, D7). The pending copy in `add-device-delete-guardrails` is updated to match. |
| `device-identity-reconciliation` "IP Alias Resolution" | a confirmed alias merges unconditionally | Superseded by the guarded version in `refactor-device-identity-reconciliation` (D1). Task 1.2. |
| `docs/docs/dire-identity-model.md` "never merge on ... MAC-only" | forbids MAC-only merges | Contradicts D5 for a globally-unique MAC in environments where it is the only hardware identifier. The doc is corrected. Randomized MACs stay excluded (D4). Task 1.3. |
| `add-device-identity-fence` enforcement vs observe-only rollout | a stale write is abandoned | Unchanged. Enforcement is the intended end state, and the formal model tracks the observe-only gap as a witness. |

## Formal model mapping

`add-dire-formal-model` enforces each requirement with properties in two specs:
`DireResolution.tla` (identity resolution against physical ground truth, with DHCP churn) and
`DireLifecycle.tla` (merge, tombstone, revival, purge, the fence).

| Requirement | Property (spec) |
|---|---|
| Address Is Evidence, Not Identity | `NoFalseMerge`, `AddressNeverMerges`, `ObservedAddressHeld` (resolution) |
| Source-Authoritative Identifiers Govern Identity | `DistinctSourceIdsNeverMerge` (resolution) |
| One Live Owner Per Strong Identifier | `TypeOK`: `owner` is a function (both) |
| Interface Identifiers Belong To Their Device | `EvidenceConverges`, `NoFalseInterfaceClaim` (resolution) |
| Randomized MACs Are Evidence Only | `NoFalseMerge` (resolution, phones environment) |
| Duplicates Converge And Stay Converged | `EvidenceConverges` (resolution); `NoZombieRevival`, `NoPurgedResurrection`, `MergedRedirectsSomewhere`, `MergeGraphAcyclic`, `NoStaleRedirect`, `UnmergeRestoresExactly` (lifecycle) |
| Identity Decisions Are Never Silent | `NoSilentDecision` (resolution) |
| Restore Soft-Deleted Devices (MODIFIED) | `RevivalBumpsRevision`, `NoZombieRevival` (lifecycle) |

## Findings the model established

- A globally-unique MAC must be able to merge. `MergePolicy` rejects every MAC-only match set,
  so a router's per-interface records never converge (`mac_only_conflicts_blocked`). The
  earlier open question is answered: this is a real gap.
- When Armis reports no MACs, an Armis record and a discovered record of the same device share
  no identifier. Only their address links them, and under these requirements an address cannot
  merge two identified records. That pair belongs in a de-duplication task (#4604).

## Open questions

- A MAC reported by two devices with different source-authoritative identifiers (cloned VMs, a
  swapped NIC) is ambiguous. Prior art (blocked values, IRE de-duplication) suggests
  quarantining it as evidence and opening a task. The model's shared-MAC environment
  restricts observers to Armis until that is decided.
- A sweep that finds no live holder for an address creates a provisional record seeded from the
  address (`SweepResultsIngestor.create_available_unknown_devices/5`). When an identified device
  later resolves at that address, the provisional record is not absorbed into it: it loses the
  address and stays live and orphaned until expiry (#4603). Whether an identified device
  should absorb a provisional address-only record at its address (recorded, since DHCP makes
  the pairing uncertain) is undecided.
