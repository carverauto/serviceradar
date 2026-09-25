# DIRE formal models

Two TLA+ models check DIRE (the Device Identity and Reconciliation Engine) against the
requirements in `openspec/changes/update-dire-strong-identity-goal`: one canonical device
record per physical device, whatever its address. The verification requirements are
`openspec/specs/dire-formal-model`; the design is
`openspec/changes/archive/2026-09-24-add-dire-formal-model/design.md`.

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
| `resolution_vacuity_*` | none | `violation:<Never...>` | The goal still merges, converges and records decisions. A goal model that never merges, or never decides, would pass vacuously. |

`resolution_vacuity_shared_mac_override` checks `NeverDecides` in the `armis_shared_mac`
environment: the goal overrides the source-authoritative id's rival record and records that
decision, so the property must fail.

Every `resolution_goal_*` configuration also checks `AddressNeverMerges`: no merge is ever
caused by address or IP-alias evidence. No address-only record in the model ever holds an alias
(sweep-created records get no alias sightings, as in the code), so absorbing one is unreachable
either way; the property guards against any change that lets address evidence merge records.

`MC*.tla` modules hold TLC-only definitions: environments, symmetry, views, vacuity predicates.

## Defect switches

| Switch | Model | Code path | Witness property |
|---|---|---|---|
| `src_attach_via_mac` | resolution | `inventory/identity/resolver.ex` `lookup_by_strong_identifiers/3` | `DistinctSourceIdsNeverMerge` |
| `mac_only_conflicts_blocked` | resolution | `inventory/identity/merge_policy.ex` `mac_only_matches?/1` (an agent check-in reporting MACs owned by two records) | `EvidenceConverges` |
| `mapper_resolves_by_address` | resolution | `network_discovery/mapper_results_ingestor.ex` `resolve_device_ids/2` (address first, then alias, then DIRE) | `NoFalseInterfaceClaim` |
| `stale_holder_keeps_address` | resolution | `inventory/sync/device_writes.ex` `resolve_record_active_ip/7` (a fresh strong claim drops the address) | `ObservedAddressHeld` |
| `silent_blocks` | resolution | MergePolicy and AliasGuard telemetry-only decisions | `NoSilentDecision` |
| `gateway_sync_no_bump` | lifecycle | `inventory/device.ex` `:gateway_sync` | `RevivalBumpsRevision` |
| `sweep_restores_merged` | lifecycle | `sweep_jobs/sweep_results_ingestor.ex` `restore_eligible?/1` | `NoZombieRevival` |
| `fence_observe_only` | lifecycle | `inventory/identity/fence.ex` (no enforcing caller) | `NoStaleCommit` |
| `unmerge_restores_matches` | lifecycle | `inventory/identity/merge_engine.ex` `reassign_original_identifiers/4` | `UnmergeRestoresExactly` |
| `purge_forgets_redirect` | lifecycle | `inventory/identity/resolver.ex` `do_follow_canonical/3` | `NoPurgedResurrection` |

Code paths are relative to `elixir/serviceradar_core/lib/serviceradar/`.

## Fixed defects

| Switch | Fixed in | Now enforced by |
|---|---|---|
| `sync_alias_merge_unguarded` | #4609 (`AliasGuard.distinct_identified_devices?/3` in `Sync.Aliases`) | `NoFalseMerge`, `AddressNeverMerges` in every `resolution_goal_*` |
| `alias_merge_on_unknown_mac` | #4610 (`AliasGuard.maybe_merge_ip_alias_device/3` never merges: an identified alias holder has the alias invalidated, an address-only holder is left alone) | `NoFalseMerge`, `AddressNeverMerges` in every `resolution_goal_*` |
| `upsert_revives_merged` | #4614 (the `DeviceWrites` upsert's `on_conflict` WHERE skips a merged-away row and `follow_merged_away_uids/2` redirects that write's identifiers to the survivor; any other revival bumps `identity_revision`) | `lifecycle_goal`; `RevivalBumpsRevision` joins `lifecycle_current` once `gateway_sync_no_bump` is fixed, `NoZombieRevival` once `gateway_sync_no_bump` and `sweep_restores_merged` are; the `upsert_zombie` witness needed this switch and went with it |
| `follow_stale_audit` | #4616 (`Resolver.do_follow_canonical/3` follows only a `deleted_reason = "merged"` tombstone) | `NoStaleRedirect`, `MergeGraphAcyclic` in `lifecycle_current`; the `merge_cycle` witness needed this switch and went with it |

## Resolution environments

Each environment stands for a real situation:

| Environment | Situation |
|---|---|
| `armis_macs` | Two Armis devices; Armis reports their MACs. |
| `armis_nomacs` | Two Armis devices; Armis reports only its id. The Armis record and a discovered record of the same device share no identifier, so they cannot converge automatically (a de-duplication task, #4604). |
| `mixed` | One Armis device (no MACs reported) and one device seen only by network discovery. |
| `router` | One multi-interface router; each interface has its own MAC and address. |
| `phones` | Two devices with randomized (locally-administered) MACs. |
| `agents` | An Armis device (no MACs reported) and a device running an agent; the agent's check-ins go through the Resolver and AliasGuard. |
| `router_agent` | A router running an agent; its interfaces are sighted one MAC at a time before the agent reports them all. |
| `armis_shared_mac` | Two Armis devices reporting the same MAC (cloned VMs, a swapped NIC). Observers are limited to Armis until the quarantine question in the goal design is decided. |

## Traces recorded from the real code

`traces/Trace_<name>.tla` and `.cfg` are generated by
`elixir/serviceradar_core/test/serviceradar/inventory/dire_resolution_trace_test.exs` through
`ServiceRadar.DireTrace` (`test/support/dire_trace.ex`). Each test builds a synthetic physical
world, drives the real ingestion entry points step by step (`SyncIngestor`,
`MapperResultsIngestor`, `AgentGatewaySync`), and records the full model state after every
step:

- database state: records, merge redirects, identifier owners, addresses, confirmed aliases,
  interface-MAC claims;
- ground truth that only the harness knows: DHCP leases, and which physical device each
  observation came from;
- the identity decisions the code made (telemetry) and recorded (persisted rows).

`DireResolutionTrace.tla` pins every variable to the logged state at every step and requires
the model's `Next` to allow each transition. A matched trace reaches its last state, so its
target expects `violation:TraceIncomplete`. The `__tamper_<var>` variants of one trace each
alter a single variable in the final state and must not be matched, which proves no variable
goes unchecked.

The lifecycle traces come from
`elixir/serviceradar_core/test/serviceradar/inventory/dire_lifecycle_trace_test.exs` through
`ServiceRadar.DireLifecycleTrace` (`test/support/dire_lifecycle_trace.ex`), which drives the
lifecycle entry points: ingest (`SyncIngestor`, `AgentGatewaySync`), `MergeEngine` merge and
unmerge (including the resolver's conflict merge), `Device :soft_delete`,
`SweepResultsIngestor` restores, and `DeviceCleanupWorker` purges. It records device status and
delete reason, identifier owners, addresses, the `merge_audit` rows and the devices each step's
`identity_revision` moved. An ingest is logged as the model's `StartWork` and `Commit`; the code
runs them in one call, so `work` is never stale in a recorded trace and the
`fence_observe_only` switch stays model-only until the fence is enforced (#4618). Two values
are ghosts the harness supplies: which identifiers a merged-away device owned when the merge
ran (`srcIds`), and the insertion order of `merge_audit` rows, whose `created_at` has
one-second precision. `DireLifecycleTrace.tla` checks them the same way.

Each lifecycle trace is also rejected by the model with the defect switch it demonstrates
turned off, so each one proves its defect on the real code:

| Trace | Switch | Issue |
| --- | --- | --- |
| `conflict_unmerge` | `unmerge_restores_matches` | #4619 |
| `sweep_restores_merged` | `sweep_restores_merged` | #4617 |
| `gateway_sync_revival` | `gateway_sync_no_bump` | #4615 |
| `purge_recreate` | `purge_forgets_redirect` | #4620 |

A trace whose defect is fixed stays as a regression trace, with no knockout: `stale_redirect`
(#4616) records the fixed resolver keeping a device deleted after an unmerge on its own uid, and
`soft_delete_upsert_revival` (#4614) records the upsert reviving a soft-deleted device with an
`identity_revision` bump.

The integration test compares every freshly recorded trace with the committed file. When the
code's behavior changes, that comparison fails. Regenerate on a scratch database with
`DIRE_TRACE_WRITE=1` and commit the new trace; the model check then decides whether the model
still describes the code. The traces' `.cfg` files carry the switches today's code has (each
test's `@current_bugs`).

## Fixing a defect

1. Fix the code path named in the switch table.
2. The trace test for that path fails, because the real code's trace changed. Regenerate the
   trace with `DIRE_TRACE_WRITE=1`; its model check now fails too, because the switched-on model
   does not allow the fixed behavior.
3. Remove the switch from the model (keep only the intended branch).
4. Delete its witness configuration and target and, for a lifecycle switch, the trace's
   `__knockout` configuration and target, which TLC can no longer reject.
5. Add its property to `lifecycle_current.cfg` (lifecycle) or confirm it in every
   `resolution_goal_*` configuration (resolution).

## What the models do not express

- Numeric revision values. `identity_revision` is abstracted to "bumped this step" and "stale
  since pin", which is all the properties ask. Revision reuse after a purge and re-insert is
  therefore invisible.
- Provisional topology sightings. `MergeEngine`'s distinct-MAC veto applies only to them, and
  the resolution model does not create them, so it checks the unguarded path.
- Alias confirmation thresholds. An alias sighting is either confirmed or not.
- Absorbing a provisional address-only record into an identified device. The goal never merges
  on address evidence, so such a record stays separate; whether it should be absorbed, and how
  that would be recorded, is an open question in
  `openspec/changes/update-dire-strong-identity-goal/design.md`.
- Merge policy details beyond identifier classes. Agent-identity guards and the cooldown are
  in the lifecycle model or left nondeterministic.

## Running deeper

Bounds live in the `.cfg` files. To explore further locally, raise `MaxAudit`, add a device to
`Devices`, or add an interface or address to a resolution environment, then run the target.
Keep the committed bounds within the test's `size`.
