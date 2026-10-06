# DIRE formal models

Two TLA+ models check DIRE (the Device Identity and Reconciliation Engine) against the
requirements in `openspec/specs/device-identity-reconciliation`: one canonical device
record per physical device, whatever its address, and whatever id its source reports it
under. The verification requirements are `openspec/specs/dire-formal-model`; the design is
`openspec/changes/archive/2026-09-24-add-dire-formal-model/design.md`, and the source id
change (re-keying, retirement, succession, the grace delete and the sweep's restore) is D10 of
`openspec/changes/add-source-id-succession/design.md`.

Run them all with `bazel test --config=remote //formal/dire/...`; `make test` runs them too.

## The models

- `DireResolution.tla` models identity resolution against physical ground truth. Physical
  devices own interfaces, and each interface has a true MAC (hardware or randomized) and leases
  an address. DHCP moves addresses between interfaces. Observers report what they would
  really see:
  - Armis sync: the Armis device id, plus MACs when Armis reports them.
  - Network discovery: every interface MAC.
  - ARP-style observation: one MAC and its address. A randomized MAC from this observer is
    not registered, so that sighting is address-only.
  - Sweep: the address only.

  Each observation is resolved following `Resolver.do_resolve_device_id/2`, the sync ingestor
  and `Sync.Aliases`. A ghost variable, `phys`, tracks which physical devices built each
  record, so "one record describes two devices" is a checkable invariant.

  The id the source reports each device under is a variable, `srcOf`:
  - `Rekey` makes the source report a device under another id, or join or leave the source.
    Only an environment that sets `Rekeys` re-keys, so every other environment keeps its
    state space. Under `FreshIds` a new id is one the source never issued; otherwise it may
    re-issue an id DIRE has retired.
  - `Collect` activates an exact source collection. Each id it does not report ages on a
    coarse absence clock (`absence`): `Fresh`, then `Stale`, which stands for "absent from N
    consecutive exact collections and for at least T". One absence never retires an id.
  - `RetireAbsent` moves a stale id a record still holds into the archive
    (`device_identifier_archive`, the variable `archive`), remembering the record it held. Ingest
    reads the archive: a retired id keeps its veto against another id, anchors its record against
    seed adoption, and returns to its record only by reactivation. The code moves the record's
    `integration_id` derived from the retired id with it, so the model's one source id stands
    for both.
  - `Succeed` is the reconciler's succession merge. A predecessor holding only retired ids
    merges with the successor holding the current one only when a MAC links them, their
    observations corroborate, and the pairing is one-to-one in both directions. The ghost
    `recFs` says whose first-seen time a record carries, and an equal one corroborates on its
    own. A hostname (`HostOf`) corroborates only under D3's time guard: the source first saw the
    successor after it last saw the predecessor. The ghost `seenWith` stands for that order,
    holding the ids already issued at a record's last sighting. Under an id in
    `NewFirstSeenIds` the source reports a device with a new first-seen time, so only the
    hostname corroborates a re-key to it. `Review` records every weaker pairing as a
    `succession_review` decision and merges nothing.
  - An identified write observed at an address takes it from the record holding it, which
    releases it in the same transaction, and the conflict is recorded (#4639). Under D7 the
    holder keeps it only against a write observed before it, comparing `identity_observed_at`,
    and a holder with none is older. The model has no clock: a source sync, an agent check-in
    and a mapper poll are each the newest identity-bearing observation of their device and
    always take the address. A census carries no time of its own, only its record's last
    identity-bearing one, which the variable `idSeen` says the record has. A census record
    with none never displaces a holder that has one, and when both have one either may be
    newer. A sweep, a census and an address-only poll never set `idSeen`.
  - A sweep seed that releases its address to an identified device and holds no identifier
    and no archived one is soft-deleted as `seed_released` in the same transaction (D8). The
    model writes it as a record that no longer exists.
- `DireLifecycle.tla` models the merge lifecycle: merge, unmerge, soft delete, ephemeral
  expiry, the revival paths, purge, and the identity fence. Its identifiers are the strong
  ones; randomized MACs and addresses are evidence and are not in `Ids`, so `Expire` applies
  only to a live device owning none (`ExpiryKeepsStrongIdentity`, #4603).
  `lifecycle_vacuity_expire` expects `NeverExpires` to fail, so that property cannot pass
  vacuously.

  It also models the end of a record whose source ids all retired, and the sweep:
  - `Retire` archives source or agent ids a live record holds (the variable `arch`) and bumps
    the record, since the archive transaction moves its `identity_revision`. The constant
    `MacIds` says which identifiers are MACs, and a MAC never retires. When the ids retired are
    every id the record holds but its MACs, the same step marks the record (`marked`,
    `source_retired_at`); this is the design's `MarkRetired`. A record that gains a source or
    agent id loses the mark. A MAC neither withholds the mark nor clears it, and stays with the
    record while it is marked and as a tombstone (`MarkedHoldsOnlyMacs`).
  - `GraceDelete` soft-deletes a marked record with reason `source_retired` and releases its
    address.
  - A write reporting one of a record's retired ids, or one of a record merged into it, moves the
    archive rows back and bumps the record, live or not. This step, `Reactivate`, is the only
    write that restores a `source_retired` tombstone. Any other sighting of a `source_retired`
    or `seed_released` tombstone is dropped, as the write to a merged-away row is.
  - `Sweep` matches the live holder of the address, or else a tombstone. It restores an expired
    tombstone whatever its sources, never a merged-away or retained one, and any other by
    `restore_eligible?/1`'s rule (`SweepRestore`). Otherwise it writes the sighting to a live
    record (`SweepRefresh`) and leaves a tombstone exactly as it was (`SweepSkip`).
    `SweepCreate` seeds a row that never existed at an address no row holds, and marks it
    sweep-only (`sweepOnly`). Three things clear that flag: a write from any other source, an
    agent check-in, and merging in a record another source found.
  - `ExpiryEnabled` and `RetirementEnabled` turn expiry and retirement on and off, as
    `DeviceCleanupSettings` does.

Every action names the Elixir function it models. Each model describes the code as it is.
Known defects are switches in a `Bugs` constant, and an action takes its defective branch only
when its switch is on. Design alternatives rejected for identity safety are a separate
constant of the resolution model, `Unsafe` (see Rejected alternatives); no goal or trace
configuration sets it.

## Configurations

| Kind | Switches | Expected | Meaning |
|---|---|---|---|
| `*_goal*` | none | pass | The goal requirements hold for the intended design. |
| `*_witness_<switch>` | one (or a named pair) | `violation:<Property>` | The defect is still present in the model. |
| `lifecycle_current` | all lifecycle switches | pass | The lifecycle invariants that hold even for today's code. |
| `resolution_vacuity_*`, `lifecycle_vacuity_*` | none | `violation:<Never...>` | The goal still does each thing a property is about: it merges, converges, records decisions, merges a re-keyed pair, merges one on its hostname alone, leaves an address a census reports with a record the census does not identify, expires, grace-deletes (a record still holding a MAC among them), reactivates a retired id and restores an expired sweep-only device. A goal model that never did one of them would pass that property vacuously. |
| `resolution_unsafe_<alternative>` | none; one `Unsafe` alternative | `violation:NoFalseMerge` | The rejected alternative still merges two physical devices. If TLC finds no violation, or a different one, the target fails. |

The lifecycle goal is split so that each check stays inside its budget. `lifecycle_goal` (three
devices) and `lifecycle_goal_no_expiry` run with `RetirementEnabled = FALSE`. Three
configurations of their own check retirement, the grace delete and reactivation:
`lifecycle_goal_retirement` (two devices, two source identifiers),
`lifecycle_goal_retirement_mac` (two devices, a source identifier and a MAC) and
`lifecycle_goal_retirement_chain` (a three-device merge chain, one identifier).
`lifecycle_vacuity_grace_delete_mac` expects `NeverGraceDeletesMacHolder` to fail, so the MAC
configuration grace-deletes a record that still holds its MAC. `lifecycle_current` turns both
expiry and retirement on, so today's switches are checked against every action.

`lifecycle_goal_no_expiry` sets `ExpiryEnabled = FALSE`. Every property the models check is a
safety property, and turning an action off only removes behaviors, so today the configuration
cannot fail where `lifecycle_goal` passes. It guards against a later property that would rest
on expiry running.

`resolution_vacuity_shared_mac_override` checks `NeverDecides` in the `armis_shared_mac`
environment: the goal overrides the source-authoritative id's rival record and records that
decision, so the property must fail.

`resolution_vacuity_census_keeps_holder` checks `NeverCensusKeepsHolder` in the `armis_nomacs`
environment: a census reports a MAC at an address an Armis record holds, the census's record has
no identity-bearing observation, and the Armis record keeps the address. `ObservedAddressHeld`
allows that after a census only, so the property must fail, or that allowance is vacuous.

Every `resolution_goal_*` configuration also checks `AddressNeverMerges`: no merge is ever
caused by address or IP-alias evidence. No address-only record in the model ever holds an alias
(sweep-created records get no alias sightings, as in the code), so absorbing one is unreachable
either way; the property guards against any change that lets address evidence merge records.

Every `resolution_goal_*` configuration also checks `AliasFollowsSyncedDevice`: after a source
sync observes a device at an address, every identified record keeping a confirmed alias of the
address describes that device. It is checked after source syncs only: a census runs no alias
pass, and AliasGuard runs only on the resolver's strong-match branch. The two defect switches
that broke it are fixed (Fixed defects).

Every `resolution_goal_*` configuration also checks the source id change properties:
- `OneSourceRecordPerDevice`: at rest, at most one live record holding a source id describes
  each physical device. At rest means every id the source stopped reporting has been absent
  long enough to retire, and neither the retirement job nor the reconciler would change anything.
- `CurrentSourceIdResolves`
- `NoMergeOfCurrentSourceIds`
- `SuccessionIsCorroborated`
- `NoAddresslessShell`

Without `Rekeys` the source id never changes, so in those environments they guard the existing
paths.

`MC*.tla` modules hold TLC-only definitions: environments, symmetry, views, vacuity predicates.

## Defect switches

Each switch is a defect today's code has, confirmed against the code before it was added.
`CurrentBugs.tla` lists them for every configuration and trace that describes today's code.
Each is fixed by a decision in `openspec/changes/add-source-id-succession/design.md`, or
listed there as an open question until one is made; a new defect gets a row here.

No switch is open today: `ResolutionBugs` and `LifecycleBugs` are both empty, and every switch
the models had is listed under Fixed defects.

| Switch | Model | Code path | Fix | Witness property |
|---|---|---|---|---|

Each witness configuration is `<model>_witness_<switch>`. Code paths are relative to
`elixir/serviceradar_core/lib/serviceradar/`.

## Fixed defects

| Switch | Fixed in | Now enforced by |
|---|---|---|
| `sync_alias_merge_unguarded` | #4609 (`AliasGuard.distinct_identified_devices?/3` in `Sync.Aliases`) | `NoFalseMerge`, `AddressNeverMerges` in every `resolution_goal_*` |
| `alias_merge_on_unknown_mac` | #4610 (`AliasGuard.maybe_merge_ip_alias_device/3` never merges: an identified alias holder has the alias invalidated, an address-only holder is left alone) | `NoFalseMerge`, `AddressNeverMerges` in every `resolution_goal_*` |
| `upsert_revives_merged` | #4614 (the `DeviceWrites` upsert's `on_conflict` WHERE skips a merged-away row and `follow_merged_away_uids/2` redirects that write's identifiers to the survivor; any other revival bumps `identity_revision`) | `RevivalBumpsRevision` in `lifecycle_current` (with #4615), `NoZombieRevival` (with #4615 and #4617); the `upsert_zombie` witness needed this switch and went with it |
| `gateway_sync_no_bump` | #4615 (an agent check-in restores a soft-deleted device through `Device :gateway_restore`, which bumps `identity_revision`, and follows the merge of a merged-away one; `:gateway_sync` no longer clears a tombstone) | `RevivalBumpsRevision` in `lifecycle_current`; `NoZombieRevival` (with #4614 and #4617) |
| `sweep_restores_merged` | #4617 (`SweepResultsIngestor.eligible_restore_uids/2` never restores a `deleted_reason = "merged"` tombstone, and logs and counts each skip) | `NoZombieRevival` in `lifecycle_current` (with #4614 and #4615) |
| `stale_holder_keeps_address` | #4639 (`DeviceWrites.claim_address_from_holder/4`: a strong-identified write observed at the address (`SourcePolicy.observed_address_source?/1`) more recently than the holder's `last_seen_time` takes it, the stale holder releases it in the same transaction, and an `active_ip_conflict` row records it), then #5085 (D7: `claim_address_from_holder/5` compares `identity_observed_at`, which only an identity-bearing observation writes, where it compared a `last_seen_time` a sweep or a census refreshes; a holder with none is older, and a holder whose source ids have all retired yields to a write carrying a current one) | `ObservedAddressHeld`, `NoSilentDecision` in every `resolution_goal_*`; traces `armis_dhcp` step 8, `agent_stale_armis_holder`, `mapper_stale_address` |
| `follow_stale_audit` | #4616 (`Resolver.do_follow_canonical/3` follows only a `deleted_reason = "merged"` tombstone) | `NoStaleRedirect`, `MergeGraphAcyclic` in `lifecycle_current`; the `merge_cycle` witness needed this switch and went with it |
| `unmerge_restores_matches` | #4619 (every merge records the source's own identifiers in `merge_audit.details.source_identifiers`; `MergeEngine.reassign_original_identifiers/4` restores exactly those the survivor still holds) | `UnmergeRestoresExactly` in `lifecycle_current` |
| `purge_forgets_redirect` | #4620 (`Resolver.do_follow_canonical/3` and `BatchResolver` follow a purged merged-away uid through its newest merge row unless an unmerge reversed it) | `NoPurgedResurrection` in `lifecycle_current` (with #4618, which removed the `purge_zombie` witness) |
| `silent_blocks` | #4613 (`Identity.DecisionLog` writes `platform.identity_decisions` for every blocked, declined or overridden merge) | `NoSilentDecision` in every `resolution_goal_*`; each trace's `recorded` set is read from those rows |
| `src_attach_via_mac` | #4611 (`SourceAuthorityGuard.source_mismatch?/3` in `BatchResolver` and `Resolver`; the override is a `source_override` identity decision plus a `source_authoritative_override` conflict row) | `DistinctSourceIdsNeverMerge`, `NoSilentDecision` in every `resolution_goal_*`; trace `src_attach_shared_mac` |
| `fence_observe_only` | #4618 (`Identity.Fence.fenced_write/3`: `SyncIngestor` and `AgentGatewaySync` lock the pinned device rows, withhold a stale write, re-resolve and retry once, then abandon with telemetry; `MergeEngine` locks both device rows first) | `NoStaleCommit` in `lifecycle_current`; proven on the real code by `fence_enforcement_test.exs`, since a black-box trace cannot schedule a transition inside the write |
| `mapper_resolves_by_address` | #4638 (`MapperResultsIngestor.resolve_device_ids/2` resolves a polled device by its interface MACs through the Resolver) | `NoFalseInterfaceClaim` in every `resolution_goal_*` |
| `mac_only_conflicts_blocked` | #4612 (`MergePolicy.merge_allowed_for_matches?/1` accepts a match set holding a globally-unique MAC; an all-randomized set stays blocked, and a record linked only through a randomized MAC drops out of the merge as a recorded `randomized_mac_link` policy block) | `EvidenceConverges` in every `resolution_goal_*`; traces `router_mac_only`, `agent_mac_split` |
| `randomized_mac_seeds_uid` | #4760 (`Ids.has_strong_identifier?/1` counts a MAC only when it is universally administered, and `Ids.generate_deterministic_device_id/1` names an update with no strong identifier by its address, so a census sighting of a randomized MAC is address-only) | `RandomizedMacsNeverIdentify` in every `resolution_goal_*`; trace `census_randomized_mac` |
| `seed_adopts_existing` | #4705 (`DeviceWrites.resolve_record_active_ip/7` adopts an anchorless provisional seed only for a record that is not yet a device; an existing device at a seeded address takes it under the #4639 rule, the seed releases it and stays live, and the conflict is recorded) | `ObservedAddressHeld`, `NoSilentDecision` in every `resolution_goal_*`; trace `armis_moves_onto_sweep_seed` |
| `released_seed_stays_live` | #5085 (D8: `DeviceWrites.lock_and_clear_for_upsert/3` soft-deletes a seed that released its address to an identified device, in the same transaction, as `seed_released`, when only sweeps discovered it and it holds no identifier, no archived one and no alias of another address; the sync, agent and mapper paths all release through it) | `NoAddresslessShell` in every `resolution_goal_*`; trace `armis_moves_onto_sweep_seed` |
| `armis_alias_pass_blind` | #5135 (D16: `Sync.Aliases` looks an address's aliases up under the partition `AliasEvents` records them under, the device's (`AliasEvents.alias_partition/2`), where it looked under the partition the update's identifiers are filed in, which for a sync naming its integration source is the source's own (`Ids.identifier_partition/2`), and never found one) | `AliasFollowsSyncedDevice` in every `resolution_goal_*`; trace `armis_dhcp` |
| `foreign_sighting_confirms_alias` | #5135 (D16: `AliasEvents.process_alias/5` records a sighting on the sighted device's own row (`DeviceAliasState.lookup_for_device/4`), where it took the first row of the address, whichever device it named. With a row per device, `Sync.Aliases` and `AliasGuard` handle every confirmed holder of the address but the device itself, every reader that picks one holder takes them in `DeviceAliasState.holder_sort/0`'s order, and a merge folds a row both records hold instead of rolling back on the unique key) | `AliasFollowsSyncedDevice` in every `resolution_goal_*`; traces `src_rekey_succession`, `armis_dhcp_two_holders`, `mapper_prior_alias_holder` |
| `sweep_recreates_purged_seed` | #5370 (task 9.7: `SweepResultsIngestor.seed_uids/3` reads the merge rows naming the uids a batch's new seeds derive from their addresses; a uid that redirects to a merge survivor gives way to the next uid of the chain `Ids.reseeded_device_id/1` derives that does not, within a bound, and a host whose chain has none, or whose uid cannot be resolved, is not seeded and is logged) | `NoPurgedResurrection` in `lifecycle_current` (with #4620); trace `purged_seed_sweep` |
| `sweep_refreshes_expired_tombstone` | #5370 (D12: `SweepResultsIngestor.eligible_restore_uids/2` restores an expired (`stale_ephemeral`) tombstone whose address answered, whatever its discovery sources, through `Device :restore`, which bumps `identity_revision` and leaves a `device_revival_audit` row; one the sweep finds down stays deleted. The restore runs before the availability and unavailability updates, which, like the appended `sweep` discovery source, write only a live record (`deleted_at IS NULL`)) | `ExpiredDeviceReturns`, `SweepWritesOnlyLiveRecords` in `lifecycle_current`; traces `expired_sweep_only_returns`, `sweep_restores_merged` |
| `retired_source_id_vetoes` | #5075 (`Identity.SourceRetirement.run/2`, which `SourceRetirementWorker` runs after an exact Armis collection activates, moves an Armis device id absent from N consecutive exact collections and unreported for T into `device_identifier_archive`, with the `integration_id` derived from it, and records a `source_id_retired` decision naming the proving collections; `SourceAuthorityGuard` reads the archive, so the retired id still vetoes another id and blocks automatic merges) | `OneSourceRecordPerDevice` in every `resolution_goal_*`; traces `src_attach_shared_mac`, `src_rekey_succession` (their `Retire` step) |

`stale_holder_keeps_address` was fixed twice. #4639 fixed a holder that never released the
address. The switch then named a narrower defect left in the rule #4639 added: the time the
rule compared was one a sweep or a census refreshes. #5085 compares `identity_observed_at`
instead (D7).

#4664 had no switch. The model already let a write adopt the holder of its address only when that
holder is an anchorless seed and the write creates a new record, and it never adopts for an
existing one. `AgentGatewaySync` diverged from that: it adopted any holder with no agent of its
own, or one sharing the agent's hostname. It now adopts only a holder claiming no identity the
agent does not claim, and an existing agent device takes the address under the #4639 rule. Trace
`agent_stale_armis_holder` records the fixed path; the same steps recorded from the old code are
rejected by TLC. The sync path adopted the seed for an existing record too until #4705
(`seed_adopts_existing`, under Fixed defects).

#4705 also corrected `ArpObserve`, which registered every census MAC. The census neither looks up
nor registers a randomized MAC (`SourcePolicy.include_mac_identifier?/1`); the model registers
only a globally-unique one. A trace of the old assumption (the census registering `r1`) is
matched by the previous model and rejected by this one.

## Resolution environments

Each environment stands for a real situation:

| Environment | Situation |
|---|---|
| `armis_macs` | Two Armis devices; Armis reports their MACs. |
| `armis_nomacs` | Two Armis devices; Armis reports only its id. The Armis record and a discovered record of the same device share no identifier, so they cannot converge automatically (a de-duplication task, #4604). |
| `mixed` | One Armis device (no MACs reported) and one device seen only by network discovery. |
| `router` | One multi-interface router; each interface has its own MAC and address. |
| `phones` | Two devices with randomized (locally-administered) MACs. No observer here registers one, so under the goal every sighting is address-only; `RandomizedMacsNeverIdentify` checks that no record is seeded from one. |
| `agents` | An Armis device (no MACs reported) and a device running an agent; the agent's check-ins go through the Resolver and AliasGuard. |
| `router_agent` | A router running an agent; its interfaces are sighted one MAC at a time before the agent reports them all. |
| `armis_shared_mac` | Two Armis devices reporting the same MAC (cloned VMs, a swapped NIC). Observers are limited to Armis until the quarantine question in the goal design is decided. |
| `armis_rekey` | One Armis device with one MAC, seen by Armis and the sweep. Armis may re-key it to an id it never issued, and stop reporting the old one. |
| `armis_rekey_shared_mac` | Two Armis devices reporting the same MAC, each of which Armis may re-key: a linking MAC alone must not make them one device. |
| `armis_reissued_ids` | Two Armis devices with their own MACs. Armis may re-issue an id DIRE has retired, to either device (`FreshIds = FALSE`). |
| `armis_reissued_ids_one_device` | One Armis device that Armis may re-key and later report again under an id DIRE retired from it. |
| `armis_clones` | Two devices cloned from one image, reporting the same MAC and the same hostname. Armis may stop reporting either, and the hostname must not make them one device. Both are in Armis from the start, so their lifetimes overlap. |
| `armis_rekey_new_first_seen` | `armis_rekey`, except that Armis reports the device with a new first-seen time under its new id. Only the hostname corroborates the re-keyed pair, so the time guard must let a true re-key converge. |

The `Spare` constant holds record names that no identifier or address names. A re-issued id
whose own uid already names an old record creates a record under one of them.

## Rejected alternatives

A design alternative rejected for identity safety is a member of `Unsafe`, which
`ASSUME Unsafe \subseteq UnsafeAlternatives` bounds. Each alternative has one negative
configuration that enables it alone and expects `violation:NoFalseMerge`, because the
alternative merges two physical devices.

| Alternative | Configuration | Environment | The false merge |
|---|---|---|---|
| `mac_only_succession` | `resolution_unsafe_mac_only_succession` | `armis_rekey_shared_mac` | Succession on a linking MAC alone, without corroboration: once one of two devices sharing a MAC leaves Armis, its record merges into the other's. |
| `retired_ids_forgotten` | `resolution_unsafe_retired_ids_forgotten` | `armis_reissued_ids` | Retirement without the archive: when Armis re-issues a retired id to another device, nothing remembers the record that held it, and the write lands on that record, which its uid still names. |
| `overlapping_hostname_corroborates` | `resolution_unsafe_overlapping_hostname_corroborates` | `armis_clones` | A hostname corroborates without D3's time guard: once one of two clones leaves Armis and its id retires, its record merges into the other's, because they share a MAC and a hostname. |

An alternative is never fixed, so its configuration stays when switches come and go.

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
`SweepResultsIngestor` sweeps, `EphemeralDeviceExpiry` expiry, `DeviceCleanupWorker` purges,
`SourceRetirement` retirement after exact collections without the id, and
`SourceRetiredExpiry`'s grace delete. It records device status and
delete reason, identifier owners, addresses, the `merge_audit` rows, the `source_retired` mark,
the identifier archive, which devices only the sweep discovered, and the devices each step's
`identity_revision` moved. A sweep is logged as the model's step for what it did:
`SweepCreate`, `SweepRestore`, `SweepRefresh` (it wrote its sighting to the record it found) or
`SweepSkip`. Whether a sweep wrote a row is read from the row's version, since a sighting's
one-second timestamps can equal an earlier step's. The archive is read from
`device_identifier_archive`. A merge moves an archived row to the survivor, while the model
keeps the device the id retired from and follows the merge, so no trace merges a record after
one of its ids retired. Only `source_retired_returns` retires an id, so the mark and the
archive are empty in every other trace; the tamper variants still prove both are pinned. A
source files the MACs it reports under its own partition, which a MAC-only sighting in the
default partition does not reach, so a trace's evidence sighting of a source's record is a
sweep. An ingest is logged as the model's `StartWork` and `Commit`, or `Reactivate` when a
retired id it reports leaves the archive; the code runs them in one call, so `work` is never
stale in a recorded trace: a black-box trace cannot place a transition between the pin and the
write. The enforced fence (#4618) is proven instead by
`elixir/serviceradar_core/test/serviceradar/inventory/identity/fence_enforcement_test.exs`, which
puts a merge, a purge or repeated transitions in exactly that window. Two values are ghosts the
harness supplies: which identifiers a merged-away device owned when the merge ran (`srcIds`),
and the insertion order of `merge_audit` rows, whose `created_at` has one-second precision.
`DireLifecycleTrace.tla` checks them the same way.

A trace whose defect is still present is also rejected by the model with that defect switch
turned off (a knockout, `Trace_<name>__knockout.cfg`, written by the test's
`assert_golden!(demonstrates: switch)`), which proves the defect on the real code. A trace that
reaches a state breaking a property has a witness (`Trace_<name>__witness.cfg`, written by
`assert_golden!(witness: property)`), whose target expects `violation:<property>`: the
property fails on the real code. No trace recorded today has either, since no switch is open:
every trace is a regression trace.

The resolution traces of the alias fixes (D16, #5135):

- `armis_dhcp` (#4609, #4639): a device's alias of an address is confirmed by three census
  sightings; it leaves the address and an Armis device is synced there. The Armis device takes
  the address, and the sync's alias pass, looking under the device's partition, invalidates the
  first device's alias and records it (`armis_alias_pass_blind`).
- `armis_dhcp_two_holders`: two devices in turn confirm an alias of one address and leave it; an
  Armis device synced there takes the address, and the alias pass invalidates both aliases,
  recording each. The pass used to handle only the first holder.
- `mapper_prior_alias_holder`: a device confirms an alias of an address and leaves it; a second
  device leases the address and is sighted there often enough to be its first holder, and the
  mapper polls it. AliasGuard skips the polled device's own row and invalidates the first
  device's alias. Reading only the first holder, it found the device's own row and stopped.
- `src_rekey_succession`: Armis re-keys a device. The new id gets its own record, which takes the
  address, while the old record keeps the MAC. Matching hostnames record the pair for
  de-duplication review. The new record's sightings of the address confirm a row of its own;
  they used to land on the row the old record's sync created and confirm the old record's alias
  (`foreign_sighting_confirms_alias`). Three exact collections without the old id retire it from
  the old record, which keeps it as history, so the new record is the one record holding a
  current id of the device (the regression path of `retired_source_id_vetoes`). The reconciler's
  succession pass then merges the two: the MAC links the old record to the new one alone, and
  the first-seen times agree (D3). The old record, created first, survives with the current id
  and the address.

The resolution traces of source succession (D3, D4). The first three are variants of
`src_rekey_succession`:

- `src_rekey_new_first_seen`: as `src_rekey_succession`, but the new id has a first-seen time of
  its own, later than the old id's last sighting. The hostnames agree and pass the time guard,
  so the pass merges the two.
- `src_rekey_no_macs`: as `src_rekey_succession`, but Armis reports no MAC. The hostname and the
  first-seen time agree without a MAC, so the pass records a `succession_review`
  (`corroborated_without_mac`) and merges nothing (D4).
- `src_rekey_shared_mac_rival`: two Armis devices report one MAC, and one of them is re-keyed.
  The MAC links the old record to both current records, so the pass records one
  `succession_review` naming all three (`shared_mac`) and merges nothing.
- `src_attach_shared_mac` (also a regression trace of #4611): two Armis devices report one MAC,
  and the source stops reporting one of them, whose id retires. The MAC links its record to the
  other's alone, but neither the hostname nor the first-seen time agrees, so the pass records a
  `succession_review` (`mac_only`) and merges nothing.

`census_randomized_mac` is a regression trace of `randomized_mac_seeds_uid` (#4760): two census
sightings of one randomized MAC at different addresses are address-only, each landing on the
record named by its address.

`armis_moves_onto_sweep_seed` is a regression trace of `seed_adopts_existing` (#4705) and
`released_seed_stays_live` (#5085): an Armis device synced at a new address a sweep has seeded
takes the address, and the conflict is recorded. The seed releases it and is soft-deleted as
`seed_released` in the same step.

The lifecycle regression traces:

- `stale_redirect` (#4616) records the fixed resolver keeping a device deleted after an unmerge
  on its own uid.
- `soft_delete_upsert_revival` (#4614) records the upsert reviving a soft-deleted device with an
  `identity_revision` bump.
- `gateway_sync_revival` (#4615) records an agent check-in restoring its soft-deleted device with
  a bump.
- `conflict_unmerge` (#4619) records the fixed unmerge giving back only the merged-away device's
  own identifiers.
- `expire_ephemeral` (#4603) records an address-only device expiring while a hardware-MAC device
  stays, then a sweep restoring it with a bump.
- `expired_sweep_only_returns` (`sweep_refreshes_expired_tombstone`, D12) records a host only a
  sweep knows: the sweep seeds it, it expires, and the next sweep, finding it answering,
  restores its tombstone with a bump, although no other source ever found it.
- `sweep_restores_merged` (#4617) records a sweep of a merged-away device's old address leaving
  it deleted and writing nothing to its tombstone (`SweepSkip`, D12).
- `purge_recreate` (#4620) records a source carrying a purged merged-away uid landing on the
  survivor.
- `purged_seed_sweep` (`sweep_recreates_purged_seed`, task 9.7) records a sweep seeding a host,
  a merge of the seed into a census device found at another address, and the purge of the
  merged-away seed. The next sweep of the seed's address seeds a new record, since the uid the
  address derives redirects to the survivor, and a source still carrying the purged uid lands
  on the survivor.
- `source_retired_returns` (D5, D6) records the end and the return of a record the source stops
  reporting. Exact collections without its id retire it; the record, left holding only its
  MAC, is marked `source_retired` with a bump. A sweep answering at its address leaves the mark,
  the grace pass deletes it and releases the address, and a sweep there then seeds a new
  record. When the source reports the retired id again at another address, the write
  reactivates the tombstone with a bump.

The integration test compares every freshly recorded trace with the committed file. When the
code's behavior changes, that comparison fails. Regenerate on a scratch database with
`DIRE_TRACE_WRITE=1` and commit the new trace; the model check then decides whether the model
still describes the code. The switches today's code has are listed once, in `CurrentBugs.tla`
(`ResolutionBugs`, `LifecycleBugs`); every trace `.cfg` and `lifecycle_current.cfg` reads its
`Bugs` constant from there, so a fix edits that one file rather than every trace.

## Fixing a defect

1. Fix the code path named in the switch table.
2. The trace test for that path fails, because the real code's trace changed. Regenerate the
   trace with `DIRE_TRACE_WRITE=1`; its model check now fails too, because the switched-on model
   does not allow the fixed behavior.
3. Remove the switch from the model (keep only the intended branch and its `KnownBugs` entry)
   and from `CurrentBugs.tla`. A switch left in `CurrentBugs.tla` after it leaves `KnownBugs`
   fails the models' `ASSUME Bugs \subseteq KnownBugs`.
4. Delete its witness configuration and target and the `__knockout` configuration and target
   of any trace that demonstrates it (and the test's `demonstrates:` option): with the
   switch gone the knockout checks the trace with today's switches, TLC matches it, and the
   target fails until it is deleted.
5. Add its property to `lifecycle_current.cfg` (lifecycle) or confirm it in every
   `resolution_goal_*` configuration (resolution).

## What the models do not express

- Numeric revision values. `identity_revision` is abstracted to "bumped this step" and "stale
  since pin", which is all the properties ask. Revision reuse after a purge and re-insert is
  therefore invisible.
- Provisional topology sightings. `MergeEngine`'s distinct-MAC veto applies only to them, and
  the resolution model does not create them, so it checks the unguarded path.
- Alias confirmation thresholds. A sighting either reaches the threshold or does not. Every
  device has its own row of an address, and the model keeps only the confirmed ones.
- The order of an address's alias holders. Where the code takes one holder, it takes them in
  `DeviceAliasState.holder_sort/0`'s order, and the mapper ranks by state first. The model's
  weak fallback takes any one of the holders and the address's record (`CHOOSE`), which TLC
  evaluates to one fixed element rather than to each, so the order is pinned by the tests and
  the model checks one landing per state.
- The mapper's own alias lookup. For an address no live record holds, the mapper takes the
  best-ranked alias row of a live device and reactivates the row when it is stale
  (`MapperResultsIngestor.find_device_uid_by_alias/3`). The model's mapper resolves through the
  Resolver only, and an invalidated alias never comes back.
- The sweep's fallback to a pending alias. For an address no record holds and no confirmed
  alias names, the sweep looks up pending aliases and confirms one
  (`DeviceLookup.lookup_detected_aliases_by_ip`, `confirm_from_sweep`); the model's sweep seeds
  a record there instead.
- The sweep reaching a tombstone through an alias. The sweep resolves an address with deleted
  records included, so a confirmed alias of a deleted record can resolve it there; the
  resolution model's sweep reads live records only, and the lifecycle model's matches a
  tombstone only by its address.
- Partitions. Identifiers, aliases and devices are filed under partitions, and a source's
  identifiers under the source's own; the model has one partition, so a lookup made under the
  wrong one is not modeled. The one a trace found (`armis_alias_pass_blind`) is fixed, and the
  trace `armis_dhcp` and the tests pin the fix. For the same reason a lifecycle trace never
  reaches a source's record by a MAC-only sighting.
- Hostnames reported by agents and the mapper. The model writes only the source's hostnames
  (`recFs`), so the hostname agreement it records is the source's.
- Absorbing a provisional address-only record into an identified device. The goal never merges
  on address evidence, so such a record stays separate; whether it should be absorbed, and how
  that would be recorded, is an open question in
  `openspec/changes/archive/2026-09-27-update-dire-strong-identity-goal/design.md`.
- Merge policy details beyond identifier classes. Agent-identity guards and the cooldown are
  in the lifecycle model or left nondeterministic.
- The retirement thresholds. The absence clock is coarse: an id absent from one exact
  collection is `Fresh`, and any later collection may make it `Stale`. The model cannot count N
  collections or measure T, and every collection it has is exact, so the rules that a
  collection which is not exact counts neither way and that a changed query hash restarts the
  count are left to the tests.
- Agent-id rotation, a second source and telemetry. `SrcIds` belong to one source, and agents
  never re-key. Telemetry rows are not state, so neither is re-keying them to a merge survivor.
  Agent-id rotation and moving telemetry are non-goals of the source id change.
- Imprecise succession evidence. Two devices never share a first-seen time, a device's MACs
  never change, and the archived observation of a retired id carries the MACs of the devices
  its record describes (`SrcMacs`). Hostnames may be shared (`HostOf`). The time guard is
  exact: `seenWith` orders a record's last sighting against the issue of an id, where the code
  compares timestamps at the source's precision and fails the guard on a missing one.
- The clones D3 accepts as residual. A clone that the source first sees after it last saw its
  twin, or that it reports under a re-issued id, presents the evidence of a re-key, and the
  guarded rule merges it. `armis_clones` puts both clones in the source from the start and only
  lets them leave, so their lifetimes always overlap; an environment with either residual case
  would fail `NoFalseMerge`. An operator undoes such a merge with an administrative unmerge.
- D3's rule that a hostname held by more than one current record of the source does not
  corroborate. It takes three records sharing a hostname, two of them current, and no
  environment has them. The rule only withholds a merge, so its absence hides no false merge;
  that the code still converges where it applies is left to the tests.
- One device reported under two ids at once. `srcOf` gives a device one id at a time. In the
  code both records stay current while both ids are reported; once the older id retires, its
  last sighting is later than the newer id's first, so the hostname fails the time guard and
  the pair goes to review unless their first-seen times agree.
- A new first-seen time under a re-issued id. The `armis_reissued_ids` environments keep
  `NewFirstSeenIds` empty, so each stays inside its budget.
- Creation order. A succession merge keeps the record created first; the model has no creation
  order and lets either record survive, which checks both.
- Observation times. A source sync, an agent check-in and a mapper poll always take the
  address from its holder (see The models). The code compares each write's own time with the
  holder's `identity_observed_at`: an Armis sync compares the last-seen time Armis reports,
  which may be older than an agent's or a poll's on the holder, and then the holder keeps the
  address. An agent check-in also leaves the address with a holder bound to another agent that
  is still live. The model takes neither branch, so a trace of either is rejected.
- The `seed_released` tombstone. The model writes a released seed as a record that no longer
  exists, so a later sweep of the address may seed it again at once. The code keeps the
  tombstone, and a seed's uid comes from its address, so until the purge removes the tombstone a
  sweep there seeds nothing: the model allows more than the code does.
- A seed's uid. The code names a seed by its address, and the model by a record that never
  existed. The code re-creates under its own uid a purged record nothing redirects (one never
  merged away, or whose merge an unmerge reversed), and gives a seed whose uid redirects the next
  uid `Ids.reseeded_device_id/1` derives (task 9.7); the model seeds a record that never existed
  in both cases.
- Retirement conditions and elapsed time in the lifecycle model. Any source or agent id a live
  record holds may retire, and any marked record may be grace-deleted. The absence rules, the mass
  guard, the mark's conditions and the open-review hold only ever withhold a step, so the model
  checks every path they allow.
- Availability and `last_seen_time`. A sweep's write to a record changes no modeled variable;
  only the step's name (`SweepRefresh` or `SweepSkip`) tells a write from none. A sweep that
  finds an address down is not modeled: it restores only a tombstone an answering sweep restores
  too, never an expired one, and writes only to a live record.
- What a succession merge writes besides the join. The model's `Succession` step gives the
  survivor the merged record's ids, aliases and evidence and the successor's address. In the
  code the merge also writes the source's metadata to the survivor, and a database trigger (D5)
  clears the survivor's `source_retired` mark once it holds a current id. The resolution model
  has neither, and the tests assert both.
- The succession pass's limit and its read. `max_successions_per_run` only defers a merge, so
  it hides no false merge. The pass reads its pairs before it merges them; the code checks each
  pair again under the merge's locks (`SourceSuccession.revalidate/2`) and refuses one that is
  no longer successive, where the model's step is atomic. The trace harness records at most one
  `Succession` step per reconciler run.
- Operator decisions. Only distinct agents rule a pair out in the model: it has no operator's
  assertion that two records are different devices, and no de-duplication task. The code skips
  an asserted pair, an administrative unmerge of a succession asserts the pair, and a succession
  merge marks the task opened for exactly that pair merged; the tests pin each.
- The reconciler's duplicate pass (`DuplicateSweep` merges with reason `identifier_backfill`).
  D2 requires it to refuse a pair whose records each hold or held a source id; the model checks
  that refusal on the resolver's conflict merge only.

## Running deeper

Bounds live in the `.cfg` files. To explore further locally, raise `MaxAudit`, add a device to
`Devices`, or add an interface or address to a resolution environment, then run the target.
Keep the committed bounds within the test's `size`.
