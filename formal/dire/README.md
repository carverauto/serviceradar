# DIRE formal models

Two TLA+ models check DIRE (the Device Identity and Reconciliation Engine) against the
requirements in `openspec/changes/update-dire-strong-identity-goal`: one canonical device
record per physical device, whatever its address. The verification design is
`openspec/changes/add-dire-formal-model`.

Run them all with `bazel test --config=remote //formal/dire/...`; `make test` runs them too.

## The models

- `DireResolution.tla` models identity resolution against physical ground truth. Physical
  devices own interfaces, and each interface has a true MAC (hardware or randomized) and leases
  an address. DHCP moves addresses between interfaces. Observers report what they would
  really see:
  - Armis sync: the Armis device id, plus MACs when Armis reports them.
  - Network discovery: every interface MAC.
  - ARP-style observation: one MAC and its address.
  - Sweep: the address only.

  Each observation is resolved following `Resolver.do_resolve_device_id/2`, the sync ingestor
  and `Sync.Aliases`. A ghost variable, `phys`, tracks which physical devices built each
  record, so "one record describes two devices" is a checkable invariant.
- `DireLifecycle.tla` models the merge lifecycle: merge, unmerge, soft delete, the revival
  paths, purge, and the identity fence.

Every action names the Elixir function it models. Each model describes the code as it is.
Known defects are switches in a `Bugs` constant, and an action takes its defective branch only
when its switch is on.

## Configurations

| Kind | Switches | Expected | Meaning |
|---|---|---|---|
| `*_goal*` | none | pass | The goal requirements hold for the intended design. |
| `*_witness_<switch>` | one (or a named pair) | `violation:<Property>` | The defect is still present in the model. |
| `lifecycle_current` | all lifecycle switches | pass | The lifecycle invariants that hold even for today's code. |
| `resolution_vacuity_*` | none | `violation:<Never...>` | The goal still merges and converges. A goal model that never merges would pass vacuously. |

`MC*.tla` modules hold TLC-only definitions: environments, symmetry, views, vacuity predicates.

## Defect switches

| Switch | Model | Code path | Witness property |
|---|---|---|---|
| `sync_alias_merge_unguarded` | resolution | `inventory/sync/aliases.ex` `attempt_alias_merge/5` | `NoFalseMerge` |
| `alias_merge_on_unknown_mac` | resolution | `inventory/identity/alias_guard.ex` `maybe_merge_ip_alias_device/3` | `NoFalseMerge` |
| `src_attach_via_mac` | resolution | `inventory/identity/resolver.ex` `lookup_by_strong_identifiers/3` | `DistinctSourceIdsNeverMerge` |
| `mac_only_conflicts_blocked` | resolution | `inventory/identity/merge_policy.ex` `mac_only_matches?/1` | `EvidenceConverges` |
| `silent_blocks` | resolution | MergePolicy and AliasGuard telemetry-only decisions | `NoSilentDecision` |
| `upsert_revives_merged` | lifecycle | `inventory/sync/device_writes.ex` upsert `on_conflict` | `RevivalBumpsRevision` |
| `gateway_sync_no_bump` | lifecycle | `inventory/device.ex` `:gateway_sync` | `RevivalBumpsRevision` |
| `follow_stale_audit` | lifecycle | `inventory/identity/resolver.ex` `do_follow_canonical/3` | `NoStaleRedirect` |
| `sweep_restores_merged` | lifecycle | `event_writer/processors/sweep.ex` `restore_eligible?/1` | `NoZombieRevival` |
| `fence_observe_only` | lifecycle | `inventory/identity/fence.ex` (no enforcing caller) | `NoStaleCommit` |
| `unmerge_restores_matches` | lifecycle | `inventory/identity/merge_engine.ex` `reassign_original_identifiers/4` | `UnmergeRestoresExactly` |
| `purge_forgets_redirect` | lifecycle | `inventory/identity/resolver.ex` `do_follow_canonical/3` | `NoPurgedResurrection` |

Code paths are relative to `elixir/serviceradar_core/lib/serviceradar/`.

Two lifecycle witnesses cover defects that only appear together:

- `upsert_zombie` (`upsert_revives_merged` + `fence_observe_only`): the upsert revives a merged
  device only when the fence does not stop the stale write.
- `merge_cycle` (`gateway_sync_no_bump` + `follow_stale_audit`): every redirect cycle found
  needs `follow_stale_audit` plus some revival path.

## Resolution environments

Each environment stands for a real situation:

| Environment | Situation |
|---|---|
| `armis_macs` | Two Armis devices; Armis reports their MACs. |
| `armis_nomacs` | Two Armis devices; Armis reports only its id. The Armis record and a discovered record of the same device share no identifier, so they cannot converge automatically (a de-duplication task, #4604). |
| `mixed` | One Armis device (no MACs reported) and one device seen only by network discovery. |
| `router` | One multi-interface router; each interface has its own MAC and address. |
| `phones` | Two devices with randomized (locally-administered) MACs. |
| `armis_shared_mac` | Two Armis devices reporting the same MAC (cloned VMs, a swapped NIC). Observers are limited to Armis until the quarantine question in the goal design is decided. |

## Fixing a defect

1. Fix the code path named in the switch table.
2. The trace-validation test for that path (PR 3 of `add-dire-formal-model`) fails, because
   the real code no longer behaves like the switched-on model.
3. Remove the switch from the model (keep only the intended branch).
4. Delete its witness configuration and target.
5. Add its property to `lifecycle_current.cfg` (lifecycle) or confirm it in every
   `resolution_goal_*` configuration (resolution).

## What the models do not express

- Numeric revision values. `identity_revision` is abstracted to "bumped this step" and "stale
  since pin", which is all the properties ask. Revision reuse after a purge and re-insert is
  therefore invisible.
- Provisional topology sightings. `MergeEngine`'s distinct-MAC veto applies only to them, and
  the resolution model does not create them, so it checks the unguarded path.
- Alias confirmation thresholds. An alias sighting is either confirmed or not.
- Merge policy details beyond identifier classes. Agent-identity guards and the cooldown are
  in the lifecycle model or left nondeterministic.

## Running deeper

Bounds live in the `.cfg` files. To explore further locally, raise `MaxAudit`, add a device to
`Devices`, or add an interface or address to a resolution environment, then run the target.
Keep the committed bounds within the test's `size`.
