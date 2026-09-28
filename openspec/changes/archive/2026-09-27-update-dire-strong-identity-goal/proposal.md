# Ground DIRE on one goal: a device keeps one identity across address churn

## Why

DIRE (the Device Identity and Reconciliation Engine) exists to solve one problem. Devices are
imported from IPAM and asset systems (Armis, NetBox, Infoblox) and discovered on the network,
and many of them get their addresses from DHCP. An address therefore moves between devices
over time. DIRE must keep **one canonical device record per physical device, whatever its
address**, identifying devices by strong identifiers and never by address.

- Where an asset system is the source, it supplies a source-authoritative identifier. Armis
  supplies an Armis device id with every record, and it already copes with address churn.
- Where no asset system is involved, the only strong identifier is a globally-unique MAC
  address. Network equipment has several, one per interface. Phones and many IoT devices use
  randomized, locally-administered MACs, which cannot identify a device over time.

The requirements that describe DIRE today grew by accretion and contradict each other on the
questions that matter most:

- `device-inventory` "Restore Soft-Deleted Devices" revives any tombstone a sweep matches,
  while `refactor-device-identity-reconciliation` says a merged-away device is never
  resurrected.
- `device-identity-reconciliation` merges on a strong MAC alone, while the architecture page
  (`docs/docs/dire-identity-model.md`) and an archived change forbid MAC-only merges.
- The same spec merges on a confirmed IP alias unconditionally, while the unarchived refactor
  guards that merge.
- The identity fence says a stale write is abandoned, while its rollout observed only (enforced since #4618).

A formal model built on these requirements would check that DIRE stays broken. This change
states the goal as requirements, resolves the contradictions against it, and gives the formal
model (`add-dire-formal-model`) something correct to enforce.

## What Changes

- ADDED requirements in `device-identity-reconciliation`:
  - Address Is Evidence, Not Identity
  - Source-Authoritative Identifiers Govern Identity
  - One Live Owner Per Strong Identifier
  - Interface Identifiers Belong To Their Device
  - Randomized MACs Are Evidence Only
  - Duplicates Converge And Stay Converged
  - Identity Decisions Are Never Silent
- MODIFIED `device-inventory` "Restore Soft-Deleted Devices": discovery restores a device
  deleted for any reason except a merge, and every restore is an identity transition (revision
  bump, revival audit). The pending copy of this requirement in `add-device-delete-guardrails`
  is updated to match, so archiving that change cannot bring the old wording back.
- A cleanup roadmap in `tasks.md`. Each defect the formal model confirms against these
  requirements becomes a fix, and each fix flips its model witness.

## Prior Art

The design follows established practice instead of inventing its own:

- **ServiceNow CMDB Identification and Reconciliation Engine (IRE).**
  - *Identification rules*: an ordered list of identifiers per device class.
  - *Reconciliation rules*: which source is authoritative for which attributes.
  - *Dependent items*: interfaces are identified within their parent device.
  - *De-duplication tasks* for duplicates that cannot be reconciled safely (#4604).
- **Identity resolution in customer-data platforms (for example Segment Unify).**
  - A per-identifier limit on how many values one record may hold.
  - Blocked values.
  - Both stop one noisy identifier from collapsing many records. The existing
    `CardinalityCaps` and reserved-MAC list are instances of this.
- **IETF MADINAS** (randomized and changing MAC addresses): a locally-administered MAC is not
  a durable identity. Such devices are ephemeral and age out on last-seen (#4603).

## Impact

- Affected specs: `device-identity-reconciliation` (ADDED), `device-inventory` (MODIFIED),
  and the pending delta in `add-device-delete-guardrails` (MODIFIED to match).
- Supersedes the legacy wording listed in `design.md`. Each superseded requirement is
  reconciled in its own task.
- No code changes in this change. The formal model in `add-dire-formal-model` enforces these
  requirements, and the fixes follow as separate pull requests.
- Related issues: #4603 (stale ephemeral expiry), #4604 (de-duplication tasks), #4166 (devices
  disappearing, most likely merged away rather than reaped).
