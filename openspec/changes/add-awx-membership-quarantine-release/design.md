## Context

`platform.ansible_awx_host_memberships` holds one row per AWX source tuple
`(controller_id, inventory_id, awx_host_id)`. Its `link_disposition` is `unlinked`,
`proposed`, `approved` or `quarantined`. Only an approved, current, enabled membership is
launchable, and approval is a human, evidence-bound compare-and-swap
(`AwxMembershipApproval`).

Writers that set `quarantined` today, found by searching for the attribute and the
literal rather than for an action name:

| Writer | Layer | Condition |
| --- | --- | --- |
| `AwxMembershipReconciler.link_attributes/3` | Ash upsert | more than one device matches the source tuple |
| same | Ash upsert | an approved link now matches exactly one different device |
| same | Ash upsert | an approved membership that had expired is observed again |
| same | Ash upsert | an approved link now matches no device |
| same | Ash upsert | the row is already quarantined (sticky; keeps the state) |
| `platform.trg_ansible_awx_membership_device_deleted()` | database trigger | an approved membership's canonical device row was deleted (foreign key `SET NULL`) or its identity purged (`DeviceCleanupWorker` detach) |
| `AwxHostMembership` action `:quarantine_link` | Ash update | no caller anywhere |

No writer records which condition fired. The trigger adds a `canonical_device_deleted`
key to `link_evidence`, but the approval contract requires exactly six evidence keys, and
the API view strips anything else, so the operator never sees it.

## Goals / Non-Goals

- Goals: a typed, stored reason and time for every quarantine; a human exit that cannot
  produce an approval; an append-only record of each exit; honest marking of rows whose
  cause was never stored.
- Non-Goals: changing which conditions quarantine; automatic release; the
  approved-host-reappears policy (provisioning defect 2); the settings UI (a follow-up
  task in this change); `AutomationTargetHold`.

## Decisions

### 1. Reason values

| Value | Set by | Meaning |
| --- | --- | --- |
| `ambiguous_device_match` | reconciliation | More than one device carries the AWX source tuple. Takes precedence when an approved link also changed. |
| `approved_device_changed` | reconciliation | An approved link now matches exactly one device, and it is a different device. Takes precedence over `approved_membership_not_current` when both hold. |
| `approved_link_lost_match` | reconciliation | An approved link now matches no device. |
| `approved_membership_not_current` | reconciliation | An approved membership had expired (absent from a complete observation) and was observed again. Its approval is not carried across the gap. |
| `canonical_device_deleted` | database trigger | The canonical device of an approved membership was deleted or its identity purged. |
| `predates_reason_recording` | migration only | The row was quarantined before reasons were recorded. Its cause is unknown. |

The column is `text` with a check constraint, mapped to an Ash `:atom` with `one_of`, the
same shape as `link_disposition`.

### 2. When a row was quarantined

`quarantined_at` is the source observation time (`observed_at`) for reconciliation, so a
replay of the same observation computes the same row, and the transaction time for the
trigger. A row marked `predates_reason_recording` has no time: `updated_at` changes on
every refresh and would be a guess.

### 3. Storage enforces the reason

Two check constraints: a row is quarantined exactly when it has a reason, and it has a
time exactly when its reason is not `predates_reason_recording`. A future writer that
forgets the reason fails its write instead of producing an unexplained row. The trigger
is a `BEFORE` trigger, so it sets the reason before the constraint is checked.

### 4. Quarantine stays sticky; the reason records entry, the evidence records now

Reconciliation keeps a quarantined row quarantined, as today, and keeps its reason and
time. It still refreshes `link_evidence` with the current matches, so the row shows both
why it was quarantined and what the source says now. Clearing quarantine automatically
when the evidence looks clean would hand a later device the trust of an earlier
approval, which the approved targeting requirement forbids; a person decides instead.

### 5. Release semantics

Release is a human action with the same authority model as approval: a human principal
(system actors and OAuth clients are refused), `ansible.controllers.manage` loaded fresh
from storage, and the request bound to what the reviewer saw. The request carries
exactly `controller_id`, `inventory_id`, `awx_host_id`, `source_generation`,
`source_fingerprint` and `link_evidence_digest` (the digest of the quarantined row's full
evidence). There is no `canonical_device_uid`: a quarantined row has none, and the
release chooses no device.

Under the controller's observation lock, release re-reads the row, requires it to be
quarantined, current and unexpired, compares the request, and resolves the source tuple
against current device inventory with the same query and index reconciliation uses
(`AwxMembershipReconciler.current_matches/2`). Then:

| Current matches | Result |
| --- | --- |
| exactly one | `proposed` with that device and fresh evidence; approval still required |
| none | `unlinked` with fresh evidence; the next synchronization may propose a device |
| more than one | refused with `membership_link_ambiguous` and the current matches; the row is unchanged |

The released row's evidence is exactly the six source-tuple keys, because approval
accepts only that shape. Keys merged in while the row was quarantined (the deleted-device
marker, an earlier approval record) move to the release record. Release clears the
reason and time and leaves `source_generation` alone: a release is not a source
observation. It never writes `approved`, and the action's compare-and-swap filter
requires `quarantined`, so it cannot act on any other state.

After release the row is an ordinary `proposed` or `unlinked` membership. The same
reconciliation rules apply to it, so a later ambiguity quarantines it again with a new
reason and time.

A disabled host can be released; approval still refuses a disabled one, so this cannot
make it launchable. An expired (not current) row cannot be released: its evidence comes
from a source that no longer reports the host. If the host returns, synchronization keeps
it quarantined and it can be released then.

### 6. Serialization with synchronization

Release takes the same transaction-scoped advisory lock that reconciliation takes for the
controller (`awx-inventory-observation:<controller_id>`). Without it, a synchronization
that read the quarantined row before the release committed would write it back as
quarantined after the release, with the old reason. With it, the two serialize, and the
release's device query sees the same inventory a synchronization would.

Approval does not take this lock today. A synchronization that overlaps an approval can
return an approved row to `proposed`; that fails safe and is out of scope here.

### 7. The release record

`platform.ansible_awx_membership_quarantine_releases` is append-only: its Ash resource has
create and read actions only. It holds the membership ID and source tuple, the releasing
principal, the release time, the prior reason and time, the prior full `link_evidence`,
the source generation and fingerprint at release, and the resulting disposition, device
and evidence. It has no foreign key to the membership, so history survives a controller
deletion that cascades the memberships. The release service writes the record in the same
transaction as the membership update; either both commit or neither does.

A dedicated table instead of a `SecurityEvent`: security events are pruned by retention,
and the release history belongs with the membership it explains.

### 8. Existing rows

Every row quarantined before the migration is marked `predates_reason_recording` with no
time. Their cause was never stored. Some rows carry evidence written by a writer that no
longer exists, so even a marker that looks conclusive cannot be trusted to name the rule.
The stored `link_evidence` is unchanged, and release copies it into the release record.

### 9. The unused `quarantine_link` action is removed

It has no caller, and it would quarantine without a reason. Removing it leaves the
reconciler and the trigger as the only quarantine writers.

### 10. Shared reviewer authority

Approval and release share one module for the reviewer boundary: resolving the
initiating human, reloading the user and effective authority from storage, checking the
permission, and parsing request fields. The error codes approval already returns are kept
unchanged, and release returns the same codes for the same principal failures.

### 11. No operator note

Release records who, when, the prior reason and the evidence. It does not take a
free-text justification: the owner's approved wording does not include one, and the
pending provisioning change that mentioned "a reason" is amended to match.

## Distinct from target holds

`AutomationTargetHold` is a device-wide hold placed after a failed or unproven mutation
and cleared through its own gate. A membership quarantine is about whether one AWX host
is linked to one device. They are independent: release does not clear a hold, and
clearing a hold does not release a membership. User-facing text says "membership
quarantine" and "target hold", never "quarantine" alone for both.

## Risks / Trade-offs

- Release reads up to the reconciliation ceiling of device rows for one controller to
  evaluate one tuple. It reuses the reconciliation query so the two cannot disagree; a
  release is a rare human action.
- A legacy row stays `predates_reason_recording` until it is released or the controller
  is deleted. That is the honest state.

## Migration Plan

1. Add the nullable columns, mark existing quarantined rows, add the check constraints.
2. Replace the deleted-device trigger function so it also sets the reason and time.
3. Create the release record table and its indexes.
4. Move `core.migrations.expectedVersion` in the Helm values to the new version.

Rollback (`down`) restores the previous trigger body, drops the release table, the
constraints and the columns. Releases already made remain valid `proposed` or `unlinked`
rows.
