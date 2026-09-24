# DIRE Formal Model PR 2: Resolution and Lifecycle Models Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land two TLA+ models that check DIRE against the goal requirements in
`update-dire-strong-identity-goal`: identity resolution under DHCP churn against physical ground
truth (`DireResolution.tla`), and the merge/tombstone/revival lifecycle (`DireLifecycle.tla`).
Every known defect is a switch with a witness configuration, and all 24 configurations run in
`make test`.

**Architecture:** Each model describes the code as it is, action by action, citing the function
it models; defects are switches in a `Bugs` constant. `goal` configurations (no switches) must
pass; `witness` configurations (one defect) must report one named violation; `current`
(lifecycle, every defect) checks what still holds today; `vacuity` configurations prove the goal
still merges and converges. `MC*.tla` modules hold TLC-only definitions (environments, symmetry,
views, vacuity predicates).

**Tech Stack:** TLA+ / TLC 1.7.4 through `//build/tla:tlc.bzl` (PR 1, #4598).

**Spec:** `openspec/changes/update-dire-strong-identity-goal/` (the requirements; committed on
this branch as 9465607ae9) and `openspec/changes/add-dire-formal-model/` (the verification).
Covers `add-dire-formal-model` tasks section 2 and 4.1, and `update-dire-strong-identity-goal`
tasks 2.1-2.2.

## Global Constraints

- Worktree `~/.treehouse/serviceradar-6faf2f/27/serviceradar`, branch `feat/dire-formal-model-lifecycle`.
- Commit as `git -c user.email=mfreeman@carverauto.dev -c user.name="Michael Freeman" commit`;
  messages end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.
- No production code changes. No shell scripts. Bazel with `--config=remote`.
- Model values only (`d1`, `h1`, `a1`, `m1`, `p1`); nothing from a live system.
- PR through `no-mistakes axi run --intent ...`.
- If `staging` was rewritten again, stop at the rebase gate (see the 2026-09-24 rewrite).

## What the draft already established

Every file below was run with TLC 1.7.4 on a workstation and judged by the PR 1 driver's
`judge()` before this plan was written. All 24 configurations produced their expected outcome:

| Configuration | Expected |
|---|---|
| `lifecycle_current` | `pass` |
| `lifecycle_goal` | `pass` |
| `lifecycle_witness_upsert_revives_merged` | `violation:RevivalBumpsRevision` |
| `lifecycle_witness_gateway_sync_no_bump` | `violation:RevivalBumpsRevision` |
| `lifecycle_witness_follow_stale_audit` | `violation:NoStaleRedirect` |
| `lifecycle_witness_sweep_restores_merged` | `violation:NoZombieRevival` |
| `lifecycle_witness_fence_observe_only` | `violation:NoStaleCommit` |
| `lifecycle_witness_unmerge_restores_matches` | `violation:UnmergeRestoresExactly` |
| `lifecycle_witness_purge_forgets_redirect` | `violation:NoPurgedResurrection` |
| `lifecycle_witness_upsert_zombie` | `violation:NoZombieRevival` |
| `lifecycle_witness_merge_cycle` | `violation:MergeGraphAcyclic` |
| `resolution_goal_armis_macs` | `pass` |
| `resolution_goal_armis_nomacs` | `pass` |
| `resolution_goal_mixed` | `pass` |
| `resolution_goal_router` | `pass` |
| `resolution_goal_phones` | `pass` |
| `resolution_goal_armis_shared_mac` | `pass` |
| `resolution_witness_alias_merge_on_unknown_mac` | `violation:NoFalseMerge` |
| `resolution_witness_sync_alias_merge_unguarded` | `violation:NoFalseMerge` |
| `resolution_witness_mac_only_conflicts_blocked` | `violation:EvidenceConverges` |
| `resolution_witness_silent_blocks` | `violation:NoSilentDecision` |
| `resolution_witness_src_attach_via_mac` | `violation:DistinctSourceIdsNeverMerge` |
| `resolution_vacuity_router_merges` | `violation:NeverMerged` |
| `resolution_vacuity_armis_converges` | `violation:NeverConverged` |

Slowest runs (single worker): `lifecycle_current` 59 s, `resolution_goal_armis_nomacs` 61 s,
`lifecycle_goal` 17 s. Those and the other `resolution_goal_*` runs use 8 workers.

Defects the models establish (each has a witness above):

| Switch | Model | Code path | Effect |
|---|---|---|---|
| `sync_alias_merge_unguarded` | resolution | `inventory/sync/aliases.ex` `attempt_alias_merge/5` | DHCP churn: a discovered device that left an address is merged into the Armis device that leased it, even when Armis reports MACs (no MAC veto on the sync path; the distinct-MAC veto in `MergeEngine` applies only to provisional topology sightings) |
| `alias_merge_on_unknown_mac` | resolution | `identity/alias_guard.ex` `maybe_merge_ip_alias_device/3` | An Armis device with no registered MAC is merged into the discovered device that took its old address ("unknown is not distinct") |
| `src_attach_via_mac` | resolution | `identity/resolver.ex` `lookup_by_strong_identifiers/3` | A second Armis id attaches, through a shared MAC, to a record holding a different Armis id |
| `mac_only_conflicts_blocked` | resolution | `identity/merge_policy.ex` `mac_only_matches?/1` | A router's per-interface records never converge; MergePolicy refuses globally-unique MAC evidence |
| `silent_blocks` | resolution | MergePolicy / AliasGuard | Blocked merges and alias invalidations reach only telemetry (#4604) |
| `upsert_revives_merged` | lifecycle | `inventory/sync/device_writes.ex` on_conflict | A tombstone is revived by ingest without a revision bump; with the observe-only fence, a merged device comes back |
| `gateway_sync_no_bump` | lifecycle | `inventory/device.ex` `:gateway_sync` | Revival without a bump, merged devices included |
| `follow_stale_audit` | lifecycle | `identity/resolver.ex` `do_follow_canonical/3` | A non-merge tombstone redirects through an old merge row; with any revival path this forms redirect cycles |
| `sweep_restores_merged` | lifecycle | `event_writer/processors/sweep.ex` `restore_eligible?/1` | A sweep restores a merged-away device |
| `fence_observe_only` | lifecycle | `identity/fence.ex` | A write pinned before a merge or delete still lands |
| `unmerge_restores_matches` | lifecycle | `identity/merge_engine.ex` `reassign_original_identifiers/4` | Unmerge returns none of the source's identifiers after a non-conflict merge |
| `purge_forgets_redirect` | lifecycle | `identity/resolver.ex` `do_follow_canonical/3` | After the retention purge, a merged-away uid is re-created as a new device |

## Review Focus

1. **A model action that does not match its cited function.** Task 1 step 2 compares each action to the source, including the ordering the models depend on (SyncIngestor upserts devices, then identifiers, then runs `Sync.Aliases`).
2. **A goal configuration passing vacuously.** Pinned by the two `resolution_vacuity_*` tests (committed) and Task 2 (lifecycle invariants broken once each).
3. **A `medium` target exceeding its timeout on RBE.** Task 1 step 4 records RBE durations; the fallback lowers a bound in that one `.cfg` and says so in `README.md`, never excludes the target.
4. **A witness passing on the wrong property.** The PR 1 driver rejects a different property; every witness lists only its named property.
5. **An environment that does not reflect reality.** Each `MCDireResolution.tla` environment is described in `README.md` with the real situation it stands for; the shared-MAC environment deliberately limits observers to Armis until the quarantine question in the goal design is decided.

---

### Task 1: Models, configurations and targets

**Files:**
- Create: `formal/dire/DireLifecycle.tla`, `MCDireLifecycle.tla`, `DireResolution.tla`, `MCDireResolution.tla`
- Create: the 24 `.cfg` files below
- Create: `formal/dire/BUILD.bazel`

**Interfaces:**
- Consumes: `tlc_test(name, spec, cfg, deps, expect, workers, size)` from `//build/tla:tlc.bzl`.
- Produces: `//formal/dire:<config>_test` for each configuration. PR 3's trace checks will
  `EXTENDS DireLifecycle` / `DireResolution` and use their `act` records.

- [ ] **Step 1: Write the models**

`formal/dire/DireLifecycle.tla`:

```tla
--------------------------- MODULE DireLifecycle ---------------------------
(***************************************************************************)
(* The DIRE device lifecycle as the Elixir code implements it today.        *)
(* See openspec/changes/add-dire-formal-model/design.md.                    *)
(*                                                                          *)
(* Every action names the function it models. Known defects are switches in *)
(* Bugs: an action takes its defective branch only when its switch is on.   *)
(* Paths are relative to elixir/serviceradar_core/lib/serviceradar/.        *)
(*                                                                          *)
(* Two abstractions keep the state space checkable:                         *)
(*  - identity_revision is not stored. The fence only asks whether a        *)
(*    revision moved after a pin, and the bump property only asks whether a *)
(*    revival moved it, so each step records the uids it bumped, and every   *)
(*    in-flight item is marked stale when its target is bumped.             *)
(*  - time is a "recent" flag on merge_audit rows: the merge cooldown only   *)
(*    asks whether a pair merged within the window. Tick ends the window.   *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Devices,      \* device uids
    Ids,          \* strong identifiers (device_identifiers type+value+partition)
    Ips,          \* addresses
    NoDev, NoIp,  \* "none" markers
    Bugs,         \* enabled defect switches, a subset of KnownBugs
    MaxAudit,     \* bound on merge_audit rows
    MaxWork,      \* bound on in-flight resolve->write items
    FollowDepth   \* Resolver @max_canonical_follow_depth

KnownBugs == {
    "upsert_revives_merged",     \* inventory/sync/device_writes.ex on_conflict
    "gateway_sync_no_bump",      \* inventory/device.ex update :gateway_sync
    "follow_stale_audit",        \* inventory/identity/resolver.ex do_follow_canonical/3
    "sweep_restores_merged",     \* event_writer/processors/sweep.ex restore_eligible?/1
    "fence_observe_only",        \* inventory/identity/fence.ex pin/2 has no production caller
    "unmerge_restores_matches",  \* inventory/identity/merge_engine.ex reassign_original_identifiers/4
    "purge_forgets_redirect"     \* inventory/identity/resolver.ex do_follow_canonical/3, purged uid
}

ASSUME Bugs \subseteq KnownBugs
ASSUME NoDev \notin Devices /\ NoIp \notin Ips
ASSUME FollowDepth \in Nat /\ MaxAudit \in Nat /\ MaxWork \in Nat

Bug(b) == b \in Bugs

Statuses == {"absent", "live", "tomb", "purged"}
Reasons  == {"none", "merged", "other"}
\* Merge callers, by how they fill merge_audit.details:
\*   "conflict" -> MergeEngine.merge_conflicting_devices/4: a list of BOTH sides' matches
\*   "auto"     -> Registrar (a map), AliasGuard, Resolver/BatchResolver MAC sibling,
\*                 DuplicateSweep: nothing reassign_original_identifiers/4 can read back
\*   "manual"   -> an administrative merge: bypasses merge_guard_violation/4
MergeKinds == {"conflict", "auto", "manual"}
ActNames == {"Init", "StartWork", "Commit", "CommitDropped", "Merge", "Unmerge",
             "SoftDelete", "SweepRestore", "GatewaySync", "Purge", "Tick"}

VARIABLES
    status,  \* ocsf_devices row: absent (never written), live, tomb (deleted_at set), purged
    reason,  \* deleted_reason class of the last tombstone; kept after a purge
    owner,   \* device_identifiers: identifier -> owning uid (unique index => a function)
    ipOf,    \* ocsf_devices.ip; a tombstone keeps it
    audit,   \* merge_audit rows, oldest first
    work,    \* in-flight ingest items: the uid resolved, and whether its revision moved since
    act      \* the last step, for action properties and trace validation

vars == <<status, reason, owner, ipOf, audit, work, act>>

AuditRow == [from: Devices, to: Devices, kind: {"merge", "unmerge"},
             ids: SUBSET Ids, srcIds: SUBSET Ids, recent: BOOLEAN]
WorkItem == [target: Devices, stale: BOOLEAN]
Act == [name: ActNames, u: Devices \cup {NoDev}, v: Devices \cup {NoDev},
        row: 0..MaxAudit, stale: BOOLEAN, bumped: SUBSET Devices]

MkAct(n, u, v, row, stale, bumped) ==
    [name |-> n, u |-> u, v |-> v, row |-> row, stale |-> stale, bumped |-> bumped]

TypeOK ==
    /\ status \in [Devices -> Statuses]
    /\ reason \in [Devices -> Reasons]
    /\ owner \in [Ids -> Devices \cup {NoDev}]
    /\ ipOf \in [Devices -> Ips \cup {NoIp}]
    /\ audit \in Seq(AuditRow) /\ Len(audit) <= MaxAudit
    /\ work \subseteq WorkItem /\ Cardinality(work) <= MaxWork
    /\ act \in Act

---------------------------------------------------------------------------
Live(u)       == status[u] = "live"
MergedTomb(u) == status[u] = "tomb" /\ reason[u] = "merged"
Owned(u)      == {i \in Ids : owner[i] = u}

\* A bump of the uids in B marks every in-flight item targeting one of them stale.
MarkStale(W, B) == {[target |-> w.target, stale |-> w.stale \/ w.target \in B] : w \in W}

\* ocsf_devices_unique_active_ip_idx covers live rows only, so a revival whose address a
\* live device already holds fails the write.
IpFreeFor(u, p) == p = NoIp \/ ~\E d \in Devices : d # u /\ Live(d) /\ ipOf[d] = p

\* MergeAudit read :merged_to -- from_device_id = u, reason != "unmerge", newest first.
MergeRows(u) == {k \in 1..Len(audit) : audit[k].from = u /\ audit[k].kind = "merge"}
LatestMergeRow(u) ==
    IF MergeRows(u) = {} THEN 0
    ELSE CHOOSE k \in MergeRows(u) : \A j \in MergeRows(u) : j <= k
LatestMergeTarget(u) == IF LatestMergeRow(u) = 0 THEN NoDev ELSE audit[LatestMergeRow(u)].to

\* Resolver.do_follow_canonical/3 follows u when Device.get_by_uid(u, true) returns a
\* tombstone -- whatever its deleted_reason -- and a merge row names a target. A purged
\* uid has no row, so it is never followed.
FollowsFrom(u) ==
    /\ LatestMergeTarget(u) # NoDev
    /\ LatestMergeTarget(u) # u
    /\ \/ status[u] = "tomb" /\ (reason[u] = "merged" \/ Bug("follow_stale_audit"))
       \/ status[u] = "purged" /\ reason[u] = "merged" /\ ~Bug("purge_forgets_redirect")

RECURSIVE FollowN(_, _)
FollowN(u, n) == IF n = 0 \/ ~FollowsFrom(u) THEN u ELSE FollowN(LatestMergeTarget(u), n - 1)
Follow(u) == FollowN(u, FollowDepth)

---------------------------------------------------------------------------
Init ==
    /\ status = [d \in Devices |-> "absent"]
    /\ reason = [d \in Devices |-> "none"]
    /\ owner = [i \in Ids |-> NoDev]
    /\ ipOf = [d \in Devices |-> NoIp]
    /\ audit = <<>>
    /\ work = {}
    /\ act = MkAct("Init", NoDev, NoDev, 0, FALSE, {})

\* Resolver.resolve_device_identity/2: an ingest source carrying uid u resolves it,
\* following merges, and pins the revision it saw.
StartWork(u) ==
    /\ Cardinality(work) < MaxWork
    /\ work' = work \cup {[target |-> Follow(u), stale |-> FALSE]}
    /\ act' = MkAct("StartWork", u, Follow(u), 0, FALSE, {})
    /\ UNCHANGED <<status, reason, owner, ipOf, audit>>

\* DeviceWrites insert_all(on_conflict: device_upsert_update_query(), conflict_target: [:uid])
\* -- an update with no WHERE that sets deleted_at/deleted_by/deleted_reason to NULL --
\* plus identifier registration for the written uid. S: unowned identifiers the source
\* reports; p: the address it reports (NoIp = keep the current one).
CommitWork(w, S, p) ==
    LET t     == w.target
        newIp == IF p = NoIp THEN ipOf[t] ELSE p
        bump  == CASE status[t] \in {"absent", "purged"} -> {t}  \* a new row
                   [] status[t] = "tomb" -> IF Bug("upsert_revives_merged") THEN {} ELSE {t}
                   [] OTHER -> {}
    IN
    /\ w \in work
    /\ S \subseteq {i \in Ids : owner[i] = NoDev}
    /\ UNCHANGED audit
    /\ IF w.stale /\ ~Bug("fence_observe_only")
       THEN \* Fence enforcement: the identity decision went stale; drop and re-resolve.
            /\ work' = work \ {w}
            /\ act' = MkAct("CommitDropped", NoDev, t, 0, w.stale, {})
            /\ UNCHANGED <<status, reason, owner, ipOf>>
       ELSE IF MergedTomb(t) /\ ~Bug("upsert_revives_merged")
       THEN \* Intended: a merged-away uid is never written back to life.
            /\ work' = work \ {w}
            /\ act' = MkAct("CommitDropped", NoDev, t, 0, w.stale, {})
            /\ UNCHANGED <<status, reason, owner, ipOf>>
       ELSE
            /\ IpFreeFor(t, newIp)
            /\ ipOf' = [ipOf EXCEPT ![t] = newIp]
            /\ status' = [status EXCEPT ![t] = "live"]
            /\ reason' = [reason EXCEPT ![t] = "none"]
            /\ owner' = [i \in Ids |-> IF i \in S THEN t ELSE owner[i]]
            /\ work' = MarkStale(work \ {w}, bump)
            /\ act' = MkAct("Commit", NoDev, t, 0, w.stale, bump)

\* MergeEngine.merge_devices/3 -> merge_guard_violation/4 -> do_merge_devices/5.
\* Both rows are read live; a pair merged in either direction within the cooldown
\* window is refused (recent_pair_merge?/3, which counts unmerge rows too) unless the
\* merge is manual. The agent-identity, source-authority and provisional guards and
\* MergePolicy only ever refuse, so they are left nondeterministic (design D5).
CooldownBlocks(a, b) ==
    \E k \in 1..Len(audit) : {audit[k].from, audit[k].to} = {a, b} /\ audit[k].recent

Merge(f, t, kind, S) ==
    /\ f # t /\ Live(f) /\ Live(t)
    /\ Len(audit) < MaxAudit
    /\ kind = "manual" \/ ~CooldownBlocks(f, t)
    /\ IF kind = "conflict"
       THEN S \subseteq Owned(f) \cup Owned(t) /\ S \cap Owned(f) # {} /\ S \cap Owned(t) # {}
       ELSE S = {}
    /\ owner' = [i \in Ids |-> IF owner[i] = f THEN t ELSE owner[i]]
    /\ audit' = Append(audit, [from |-> f, to |-> t, kind |-> "merge",
                               ids |-> S, srcIds |-> Owned(f), recent |-> TRUE])
    /\ status' = [status EXCEPT ![f] = "tomb"]
    /\ reason' = [reason EXCEPT ![f] = "merged"]
    /\ work' = MarkStale(work, {f, t})
    /\ act' = MkAct("Merge", f, t, Len(audit) + 1, FALSE, {f, t})
    /\ UNCHANGED ipOf

\* MergeEngine.unmerge_device/2 -> do_unmerge/4. recreate_device/3 restores a tombstone of
\* any reason (:restore bumps), leaves a live row alone, or inserts a missing one;
\* reassign_original_identifiers/4 moves back identifiers the survivor holds whose
\* {type, value} appears in details.identifiers; the survivor must be live.
Unmerge(u) ==
    LET k    == LatestMergeRow(u)
        row  == audit[k]
        s    == row.to
        back == {i \in Ids : owner[i] = s /\
                   i \in (IF Bug("unmerge_restores_matches") THEN row.ids ELSE row.srcIds)}
        bump == {s} \cup (IF status[u] = "live" THEN {} ELSE {u})
    IN
    /\ k # 0
    /\ Len(audit) < MaxAudit
    /\ Live(s)
    /\ status[u] = "tomb" => IpFreeFor(u, ipOf[u])
    /\ status' = [status EXCEPT ![u] = "live"]
    /\ reason' = [reason EXCEPT ![u] = "none"]
    /\ owner' = [i \in Ids |-> IF i \in back THEN u ELSE owner[i]]
    /\ audit' = Append(audit, [from |-> s, to |-> u, kind |-> "unmerge",
                               ids |-> {}, srcIds |-> {}, recent |-> TRUE])
    /\ work' = MarkStale(work, bump)
    /\ act' = MkAct("Unmerge", u, s, k, FALSE, bump)
    /\ UNCHANGED ipOf

\* Device :soft_delete (administrative and remediation deletes; deleted_reason /= "merged").
SoftDelete(u) ==
    /\ Live(u)
    /\ status' = [status EXCEPT ![u] = "tomb"]
    /\ reason' = [reason EXCEPT ![u] = "other"]
    /\ work' = MarkStale(work, {u})
    /\ act' = MkAct("SoftDelete", u, NoDev, 0, FALSE, {u})
    /\ UNCHANGED <<owner, ipOf, audit>>

\* SweepProcessor: DeviceLookup.batch_lookup_by_ip(include_deleted: true) prefers a live
\* holder of the address and otherwise falls back to a tombstone
\* (select_canonical_device/2); the processor restores it through :restore (which bumps)
\* when restore_eligible?/1 -- reading only discovery_sources -- allows it. Which
\* tombstone wins is left nondeterministic.
SweepRestore(p) ==
    /\ ~\E d \in Devices : Live(d) /\ ipOf[d] = p
    /\ \E d \in Devices :
         /\ status[d] = "tomb" /\ ipOf[d] = p
         /\ reason[d] # "merged" \/ Bug("sweep_restores_merged")
         /\ status' = [status EXCEPT ![d] = "live"]
         /\ reason' = [reason EXCEPT ![d] = "none"]
         /\ work' = MarkStale(work, {d})
         /\ act' = MkAct("SweepRestore", d, NoDev, 0, FALSE, {d})
    /\ UNCHANGED <<owner, ipOf, audit>>

\* AgentGatewaySync -> Device :gateway_sync on the agent's device uid clears the tombstone
\* without BumpIdentityRevision. Intended: follow a merge, and bump otherwise.
GatewaySync(u) ==
    LET bump == IF Bug("gateway_sync_no_bump") THEN {} ELSE {u} IN
    /\ status[u] = "tomb" /\ IpFreeFor(u, ipOf[u])
    /\ reason[u] # "merged" \/ Bug("gateway_sync_no_bump")
    /\ status' = [status EXCEPT ![u] = "live"]
    /\ reason' = [reason EXCEPT ![u] = "none"]
    /\ work' = MarkStale(work, bump)
    /\ act' = MkAct("GatewaySync", u, NoDev, 0, FALSE, bump)
    /\ UNCHANGED <<owner, ipOf, audit>>

\* DeviceCleanupWorker.hard_delete_records/2: the row and its device_identifiers go;
\* merge_audit rows stay. reason is kept only so the intended redirect can be modeled.
Purge(u) ==
    /\ status[u] = "tomb"
    /\ status' = [status EXCEPT ![u] = "purged"]
    /\ owner' = [i \in Ids |-> IF owner[i] = u THEN NoDev ELSE owner[i]]
    /\ ipOf' = [ipOf EXCEPT ![u] = NoIp]
    /\ work' = MarkStale(work, {u})
    /\ act' = MkAct("Purge", u, NoDev, 0, FALSE, {u})
    /\ UNCHANGED <<reason, audit>>

\* The merge cooldown window (merge_cooldown_seconds, default 86_400) elapses.
Tick ==
    /\ \E k \in 1..Len(audit) : audit[k].recent
    /\ audit' = [k \in 1..Len(audit) |-> [audit[k] EXCEPT !.recent = FALSE]]
    /\ act' = MkAct("Tick", NoDev, NoDev, 0, FALSE, {})
    /\ UNCHANGED <<status, reason, owner, ipOf, work>>

Next ==
    \/ \E u \in Devices :
         StartWork(u) \/ Unmerge(u) \/ SoftDelete(u) \/ GatewaySync(u) \/ Purge(u)
    \/ \E w \in work, S \in SUBSET Ids, p \in Ips \cup {NoIp} : CommitWork(w, S, p)
    \/ \E f, t \in Devices, kind \in MergeKinds, S \in SUBSET Ids : Merge(f, t, kind, S)
    \/ \E p \in Ips : SweepRestore(p)
    \/ Tick

Spec == Init /\ [][Next]_vars

---------------------------------------------------------------------------
(* State invariants *)

UniqueLiveIp ==
    \A a, b \in Devices : (a # b /\ Live(a) /\ Live(b) /\ ipOf[a] # NoIp) => ipOf[a] # ipOf[b]

MergedNeverOwnsIdentifiers == \A i \in Ids : owner[i] # NoDev => ~MergedTomb(owner[i])

RECURSIVE Hop(_, _)
Hop(u, n) == IF n = 0 THEN u ELSE Hop(IF FollowsFrom(u) THEN LatestMergeTarget(u) ELSE u, n - 1)

MergeGraphAcyclic ==
    \A u \in Devices : FollowsFrom(u) => \A n \in 1..Cardinality(Devices) : Hop(u, n) # u

MergedRedirectsSomewhere == \A u \in Devices : MergedTomb(u) => Follow(u) # u

NoStaleRedirect ==
    \A u \in Devices : (status[u] = "tomb" /\ reason[u] = "other") => Follow(u) = u

(* Action properties *)

NoZombieRevival ==
    [][\A u \in Devices : (MergedTomb(u) /\ status'[u] = "live") => act'.name = "Unmerge"]_vars

NoPurgedResurrection ==
    [][\A u \in Devices :
         (status[u] = "purged" /\ reason[u] = "merged" /\ status'[u] = "live")
            => act'.name = "Unmerge"]_vars

RevivalBumpsRevision ==
    [][\A u \in Devices : (status[u] = "tomb" /\ status'[u] = "live") => u \in act'.bumped]_vars

UnmergeRestoresExactly ==
    [][act'.name = "Unmerge" =>
         LET row == audit[act'.row] IN
         \A i \in Ids : owner[i] = row.to =>
             owner'[i] = IF i \in row.srcIds THEN act'.u ELSE row.to]_vars

NoStaleCommit == [][act'.name = "Commit" => ~act'.stale]_vars

=============================================================================
```

`formal/dire/MCDireLifecycle.tla`:

```tla
------------------------- MODULE MCDireLifecycle -------------------------
(* TLC harness: symmetry and a view that drops the act history variable. *)
EXTENDS DireLifecycle, TLC
Symmetry == Permutations(Devices) \cup Permutations(Ids) \cup Permutations(Ips)
StateView == <<status, reason, owner, ipOf, audit, work>>
=============================================================================
```

`formal/dire/DireResolution.tla`:

```tla
--------------------------- MODULE DireResolution ---------------------------
(***************************************************************************)
(* DIRE identity resolution against physical ground truth.                  *)
(* See openspec/changes/update-dire-strong-identity-goal (the requirements) *)
(* and openspec/changes/add-dire-formal-model (the verification).           *)
(*                                                                          *)
(* The world: physical devices own interfaces; an interface has a true MAC  *)
(* (hardware or randomized) and leases an address, and DHCP moves addresses *)
(* between interfaces. Observers report what they would really see. DIRE    *)
(* resolves each observation to a record, following                         *)
(* Resolver.do_resolve_device_id/2 step by step. A ghost variable, phys,    *)
(* tracks which physical devices' identity-bearing observations went into  *)
(* each record, so "one record describes two devices" is checkable.          *)
(*                                                                          *)
(* Merge lifecycle (tombstones, revival, purge, the fence) is modeled in   *)
(* DireLifecycle.tla; here a merged record simply redirects to its target.  *)
(* Paths are relative to elixir/serviceradar_core/lib/serviceradar/.        *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS
    Phys,          \* physical devices
    Ifaces,        \* physical interfaces
    IfPhys,        \* [Ifaces -> Phys]: the device an interface belongs to
    IfMac,         \* [Ifaces -> MacIds \cup {NoId}]: the interface's true MAC
    SrcOf,         \* [Phys -> SrcIds \cup {NoId}]: the Armis device id, if Armis knows it
    ArmisMacs,     \* whether Armis reports the device's MACs with its id
    SrcIds,        \* source-authoritative identifiers (one source)
    HwIds,         \* globally-unique MACs
    LaaIds,        \* locally-administered (randomized) MACs
    Ips,
    Observers,     \* which observers exist in this environment
    NoId, NoIp, NoRec,
    Bugs

KnownBugs == {
    "alias_merge_on_unknown_mac",  \* inventory/identity/alias_guard.ex maybe_merge_ip_alias_device/3
    "sync_alias_merge_unguarded",  \* inventory/sync/aliases.ex attempt_alias_merge/5 (no MAC veto)
    "mac_only_conflicts_blocked",  \* inventory/identity/merge_policy.ex mac_only_matches?/1
    "silent_blocks",               \* MergePolicy / AliasGuard decisions reach only telemetry
    "src_attach_via_mac"           \* inventory/identity/resolver.ex lookup_by_strong_identifiers/3
}
ASSUME Bugs \subseteq KnownBugs

Bug(b) == b \in Bugs

MacIds == HwIds \cup LaaIds
Ids    == SrcIds \cup MacIds
\* A record is named by the seed its uid was derived from: the highest-priority identifier
\* (Ids.generate_deterministic_device_id/1) or, for an identifier-less update, the address.
Recs   == Ids \cup Ips

Strong(i) == i \in SrcIds \cup HwIds
\* Ids @identifier_priority: armis_device_id before mac.
Prio(i) == IF i \in SrcIds THEN 1 ELSE IF i \in HwIds THEN 2 ELSE 3
Seed(S) == CHOOSE i \in S : \A j \in S : Prio(i) <= Prio(j)

MacsOf(h) == {IfMac[x] : x \in {y \in Ifaces : IfPhys[y] = h}} \ {NoId}
IfacesOf(h) == {x \in Ifaces : IfPhys[x] = h}

VARIABLES
    ipAt,     \* ground truth: the address each interface currently leases
    created,  \* ocsf_devices row exists
    into,     \* merge redirect: NoRec while live
    owner,    \* device_identifiers: identifier -> record
    recIp,    \* ocsf_devices.ip
    alias,    \* confirmed IP aliases: address -> records
    phys,     \* ghost: physical devices whose identity-bearing observations built the record
    act       \* the last step's identity decisions, for NoSilentDecision

vars == <<ipAt, created, into, owner, recIp, alias, phys, act>>

Decisions == {"none", "blocked", "invalidated", "absorbed", "overridden"}

TypeOK ==
    /\ ipAt \in [Ifaces -> Ips \cup {NoIp}]
    /\ created \in [Recs -> BOOLEAN]
    /\ into \in [Recs -> Recs \cup {NoRec}]
    /\ owner \in [Ids -> Recs \cup {NoRec}]
    /\ recIp \in [Recs -> Ips \cup {NoIp}]
    /\ alias \in [Ips -> SUBSET Recs]
    /\ phys \in [Recs -> SUBSET Phys]
    /\ act \in [name: STRING, silent: BOOLEAN, ids: SUBSET Ids]

Live(r) == created[r] /\ into[r] = NoRec

\* Resolver.follow_canonical_device_id/2 (correct following assumed; see DireLifecycle).
RECURSIVE CanonN(_, _)
CanonN(r, n) == IF n = 0 \/ into[r] = NoRec THEN r ELSE CanonN(into[r], n - 1)
Canon(r) == CanonN(r, Cardinality(Recs))

SrcHeldIn(o, r) == {i \in SrcIds : o[i] = r}
SrcHeld(r) == SrcHeldIn(owner, r)
MacsHeld(r) == {i \in MacIds : owner[i] = r}
IdsHeld(r) == {i \in Ids : owner[i] = r}

\* SourceAuthorityGuard.conflict_from_rows/2: two records holding disjoint, non-empty sets
\* of the same source's identifiers. Recorded (record_blocked/3).
SrcConflictIn(o, M) == \E a, b \in M : a # b /\ SrcHeldIn(o, a) # {} /\ SrcHeldIn(o, b) # {}
                                        /\ SrcHeldIn(o, a) \cap SrcHeldIn(o, b) = {}
SrcConflict(M) == SrcConflictIn(owner, M)

\* MergePolicy.merge_allowed_for_matches?/1 over the identifiers that matched.
\*   today: never an all-MAC set (globally-unique MACs included), never an all-randomized set
\*   goal:  any set containing a source-authoritative or globally-unique identifier
PolicyAllows(matched) ==
    IF Bug("mac_only_conflicts_blocked")
    THEN matched \cap SrcIds # {}
    ELSE matched \cap (SrcIds \cup HwIds) # {}

\* AliasGuard.distinct_strong_identity_conflict?/3: both records hold MACs and the sets are
\* disjoint. "Unknown is not distinct": a record with no MAC never vetoes.
DistinctMacs(a, b) == MacsHeld(a) # {} /\ MacsHeld(b) # {} /\ MacsHeld(a) \cap MacsHeld(b) = {}

---------------------------------------------------------------------------
Init ==
    /\ ipAt = [x \in Ifaces |-> NoIp]
    /\ created = [r \in Recs |-> FALSE]
    /\ into = [r \in Recs |-> NoRec]
    /\ owner = [i \in Ids |-> NoRec]
    /\ recIp = [r \in Recs |-> NoIp]
    /\ alias = [p \in Ips |-> {}]
    /\ phys = [r \in Recs |-> {}]
    /\ act = [name |-> "Init", silent |-> FALSE, ids |-> {}]

\* DHCP: an interface leases a free address or releases its lease.
Lease(x, p) ==
    /\ p # ipAt[x]
    /\ p = NoIp \/ ~\E y \in Ifaces : ipAt[y] = p
    /\ ipAt' = [ipAt EXCEPT ![x] = p]
    /\ act' = [name |-> "Lease", silent |-> FALSE, ids |-> {}]
    /\ UNCHANGED <<created, into, owner, recIp, alias, phys>>

\* One observation of physical device h, seen at interface x's address, carrying the
\* identifiers S, followed through Resolver.do_resolve_device_id/2 and the write.
\* recordAlias: this update's address is recorded as a (confirmed) alias of the result.
\* syncAlias: the update came through sync ingest and runs Sync.Aliases, not AliasGuard.
Resolve(h, x, S, recordAlias, syncAlias, kind) ==
    LET p       == ipAt[x]
        srcS    == S \cap SrcIds
        \* A matched record holding a different source-authoritative identifier than the one
        \* this update carries. Today the update attaches to it anyway: conflict detection
        \* only compares identifiers that are already owned, and this update's own id is new.
        \* Goal: the source-authoritative identifier decides; such a record is not a match.
        srcMismatch(r) == srcS # {} /\ SrcHeld(r) # {} /\ SrcHeld(r) \cap srcS = {}
        allM    == {Canon(owner[i]) : i \in {j \in S : owner[j] # NoRec}}
        M       == IF Bug("src_attach_via_mac") THEN allM
                   ELSE {r \in allM : ~srcMismatch(r)}
        matched == {i \in S : owner[i] # NoRec /\ Canon(owner[i]) \in M}
    IN
    \E X \in (IF M # {} THEN M ELSE {NoRec}) :
    LET \* --- Step 1: strong-identifier conflict (merge_conflicting_devices/4) ---
        others     == M \ {X}
        conflictOk == others # {} /\ ~SrcConflict(M) /\ PolicyAllows(matched)
        \* A MergePolicy refusal reaches telemetry only; a source-authority refusal is recorded.
        conflictSilent == others # {} /\ ~SrcConflict(M) /\ ~PolicyAllows(matched)
                          /\ Bug("silent_blocks")
        step1Merged == IF conflictOk THEN others ELSE {}
        \* --- Fallback when nothing matched (resolve_fallback_device_id/3) ---
        target ==
            IF M # {} THEN X
            ELSE IF S # {} THEN Canon(Seed(S))
            ELSE LET holders == {r \in Recs : Live(r) /\ (recIp[r] = p \/ r \in alias[p])}
                 IN IF holders # {} THEN CHOOSE r \in holders : TRUE ELSE Canon(p)
        \* --- Step 2: IP-alias merge (AliasGuard.maybe_merge_ip_alias_device/3 on the
        \*     Resolver path, Sync.Aliases.process_alias_conflicts/2 on the sync path) ---
        aliasY == {y \in alias[p] : Live(y) /\ y # target /\ y \notin step1Merged}
        \* Ownership once step 1 and this update's identifier registration have landed.
        \* SyncIngestor upserts devices, then identifiers, then runs Sync.Aliases, so the
        \* sync path's guard sees the new record's identifiers; AliasGuard runs inside the
        \* resolver, before the write, and sees the earlier ownership.
        owner1 == [i \in Ids |->
                     IF owner[i] \in step1Merged THEN target
                     ELSE IF i \in S /\ owner[i] = NoRec THEN target
                     ELSE owner[i]]
        \* Goal: alias evidence absorbs only a record holding no identifier at all.
        \* AliasGuard (Resolver path): merge unless both hold MACs and they are disjoint;
        \* MergeEngine's source-authority guard still blocks disjoint Armis ids.
        \* Sync.Aliases (sync path): merge unless the source-authority guard blocks it; no
        \* MAC veto at all, and no invalidation unless the agent guard fires.
        aliasMerge(y) ==
            IF syncAlias /\ Bug("sync_alias_merge_unguarded") THEN ~SrcConflictIn(owner1, {y, target})
            ELSE IF ~syncAlias /\ Bug("alias_merge_on_unknown_mac")
            THEN ~DistinctMacs(y, target) /\ ~SrcConflict({y, target})
            ELSE IdsHeld(y) = {}      \* goal: alias evidence absorbs only an address-only record
        aliasInvalidate(y) ==
            IF syncAlias /\ Bug("sync_alias_merge_unguarded") THEN FALSE
            ELSE IF ~syncAlias /\ Bug("alias_merge_on_unknown_mac") THEN DistinctMacs(y, target)
            ELSE IdsHeld(y) # {}
        \* AliasGuard runs only on the strong-match branch; Sync.Aliases runs for every
        \* resolved sync update, including one that created its device.
        aliasRuns   == M # {} \/ syncAlias
        step2Merged == IF aliasRuns THEN {y \in aliasY : aliasMerge(y)} ELSE {}
        step2Inval  == IF aliasRuns THEN {y \in aliasY : aliasInvalidate(y)} ELSE {}
        step2Silent == step2Inval # {} /\ Bug("silent_blocks")
        merged == step1Merged \cup step2Merged
    IN
    /\ created' = [r \in Recs |-> created[r] \/ r = target]
    /\ into' = [r \in Recs |-> IF r \in merged THEN target ELSE into[r]]
    /\ owner' = [i \in Ids |-> IF owner1[i] \in step2Merged THEN target ELSE owner1[i]]
    /\ phys' = [r \in Recs |->
                  IF r = target
                  THEN phys[r] \cup UNION {phys[m] : m \in merged} \cup (IF S # {} THEN {h} ELSE {})
                  ELSE phys[r]]
    \* ocsf_devices_unique_active_ip_idx: the write takes the address from any other holder.
    /\ recIp' = [r \in Recs |->
                   IF r = target THEN p
                   ELSE IF recIp[r] = p THEN NoIp ELSE recIp[r]]
    /\ alias' = [q \in Ips |->
                   LET kept == (alias[q] \ merged) \ (IF q = p THEN step2Inval ELSE {}) IN
                   (IF alias[q] \cap merged # {} THEN kept \cup {target} ELSE kept)
                   \cup (IF recordAlias /\ q = p THEN {target} ELSE {})]
    /\ act' = [name |-> kind, silent |-> conflictSilent \/ step2Silent, ids |-> S]
    /\ UNCHANGED ipAt

\* Armis sync: the Armis device id, plus the device's MACs when Armis reports them.
\* Its update carries a non-MAC identifier, so Sync.Aliases.process_alias_conflicts/2 runs.
\* recordAlias: the update's current address is recorded as an alias sighting
\* (AliasEvents, _alias_last_seen_ip) and has reached the confirmation threshold.
ArmisObserve(h, x) ==
    /\ SrcOf[h] # NoId /\ IfPhys[x] = h /\ ipAt[x] # NoIp
    /\ \E ra \in BOOLEAN :
         Resolve(h, x, {SrcOf[h]} \cup (IF ArmisMacs THEN MacsOf(h) ELSE {}), ra, TRUE, "Armis")

\* Mapper/SNMP discovery at interface x: every interface MAC of the device. Its other
\* interface addresses are recorded as :interface_ip, a type no identity reader consults,
\* so they are not modeled as aliases.
DiscoveryObserve(h, x) ==
    /\ IfPhys[x] = h /\ ipAt[x] # NoIp /\ MacsOf(h) # {}
    /\ \E ra \in BOOLEAN : Resolve(h, x, MacsOf(h), ra, FALSE, "Discovery")

\* ARP-style observation (netprobe, a sweep that learns a MAC): one interface's MAC and address.
ArpObserve(h, x) ==
    /\ IfPhys[x] = h /\ ipAt[x] # NoIp /\ IfMac[x] # NoId
    /\ \E ra \in BOOLEAN : Resolve(h, x, {IfMac[x]}, ra, FALSE, "Arp")

\* Sweep: an address answered, nothing else. The sweep ingestor attaches the result to the
\* live holder of the address (DeviceLookup.batch_lookup_by_ip/2); when there is none,
\* SweepResultsIngestor.create_available_unknown_devices/5 creates a provisional record whose
\* uid is derived from the address (identity_source "sweep_ip_seed"). The event_writer sweep
\* processor only looks devices up and is covered by the attach branch.
SweepObserve(h, x) ==
    /\ IfPhys[x] = h /\ ipAt[x] # NoIp
    /\ Resolve(h, x, {}, FALSE, FALSE, "Sweep")

Next ==
    \/ \E x \in Ifaces, p \in Ips \cup {NoIp} : Lease(x, p)
    \/ \E h \in Phys, x \in Ifaces :
         \/ "Armis" \in Observers /\ ArmisObserve(h, x)
         \/ "Discovery" \in Observers /\ DiscoveryObserve(h, x)
         \/ "Arp" \in Observers /\ ArpObserve(h, x)
         \/ "Sweep" \in Observers /\ SweepObserve(h, x)

Spec == Init /\ [][Next]_vars

---------------------------------------------------------------------------
(* Properties -- the goal requirements (update-dire-strong-identity-goal) *)

\* Address Is Evidence, Not Identity; Randomized MACs Are Evidence Only:
\* no live record describes two physical devices.
NoFalseMerge == \A r \in Recs : Live(r) => Cardinality(phys[r]) <= 1

\* Source-Authoritative Identifiers Govern Identity.
DistinctSourceIdsNeverMerge == \A r \in Recs : Live(r) => Cardinality(SrcHeld(r)) <= 1

\* Duplicates Converge / Interface Identifiers Belong To Their Device: once an observation
\* reports identifiers together, every live record owning one of them is the same record --
\* unless two of those records hold different source-authoritative identifiers, which stay
\* separate by design (and that decision is recorded). Two sightings that share no identifier
\* cannot be linked by evidence, so a split before linking evidence arrives is not a violation.
OwnersAfter(I) == {Canon(owner'[i]) : i \in {j \in I : owner'[j] # NoRec}}
EvidenceConverges ==
    [][Cardinality(OwnersAfter(act'.ids)) <= 1
       \/ SrcConflictIn(owner', OwnersAfter(act'.ids))]_vars

\* Identity Decisions Are Never Silent.
NoSilentDecision == [][~act'.silent]_vars

=============================================================================
```

`formal/dire/MCDireResolution.tla`:

```tla
------------------------ MODULE MCDireResolution ------------------------
(* Environments for DireResolution: which physical world TLC explores. *)
EXTENDS DireResolution
\* two devices, one interface each (Armis environments, mixed, phones)
TwoIfPhys   == [x \in {"x1", "x2"} |-> IF x = "x1" THEN "h1" ELSE "h2"]
TwoHwMacs   == [x \in {"x1", "x2"} |-> IF x = "x1" THEN "m1" ELSE "m2"]
TwoLaaMacs  == [x \in {"x1", "x2"} |-> IF x = "x1" THEN "r1" ELSE "r2"]
BothArmis   == [h \in {"h1", "h2"} |-> IF h = "h1" THEN "a1" ELSE "a2"]
OneArmis    == [h \in {"h1", "h2"} |-> IF h = "h1" THEN "a1" ELSE NoId]
NoArmis2    == [h \in {"h1", "h2"} |-> NoId]
\* a router with two interfaces and a host with one
RouterIfPhys == [x \in {"x1", "x2", "x3"} |-> IF x = "x3" THEN "h2" ELSE "h1"]
RouterMacs   == [x \in {"x1", "x2", "x3"} |-> CASE x = "x1" -> "m1" [] x = "x2" -> "m2" [] OTHER -> "m3"]
\* a router alone: two interfaces, two MACs
RouterOnlyIfPhys == [x \in {"x1", "x2"} |-> "h1"]
NoArmis1 == [h \in {"h1"} |-> NoId]
\* two Armis devices reporting the same MAC (cloned VMs, a swapped NIC)
SharedMac == [x \in {"x1", "x2"} |-> "m1"]
\* vacuity: nothing is ever merged
NeverMerged == \A r \in Recs : into[r] = NoRec
\* vacuity: Armis and discovery never converge on one record
NeverConverged == ~\E r \in Recs : owner["a1"] = r /\ owner["m1"] = r
=============================================================================
```

- [ ] **Step 2: Check every action against its cited function**

Open each cited function and confirm the modeled pre- and post-conditions, paying particular
attention to: the resolver's decision order (`Resolver.do_resolve_device_id/2`: strong match,
MAC sibling, fallback; `AliasGuard` only on the strong-match branch); `SyncIngestor`'s order
(devices, identifiers, then `Sync.Aliases`); `SourceAuthorityGuard.conflict_from_rows/2`
(disjoint non-empty sets of one source); `AliasGuard.distinct_mac_conflict?/3` ("unknown is not
distinct"); `MergeEngine.provisional_topology_merge_violation/3` (the distinct-MAC veto applies
only to provisional topology sightings, which the resolution model does not create); that the sweep
ingestor creates a provisional address-seeded record only when no live device holds the
address (`SweepResultsIngestor.create_available_unknown_devices/5`); and that `AliasEvents` records the update's current
address (`_alias_last_seen_ip`) as an `:ip` alias while interface addresses are
`:interface_ip`. Fix any mismatch in the model before continuing.

- [ ] **Step 3: Write the configurations**

`formal/dire/lifecycle_current.cfg`:

```
CONSTANTS
  Devices = {d1, d2}
  Ids = {i1, i2}
  Ips = {p1}
  NoDev = NoDev
  NoIp = NoIp
  MaxAudit = 3
  MaxWork = 1
  FollowDepth = 5
  Bugs = {"upsert_revives_merged", "gateway_sync_no_bump", "follow_stale_audit", "sweep_restores_merged", "fence_observe_only", "unmerge_restores_matches", "purge_forgets_redirect"}
SPECIFICATION Spec
SYMMETRY Symmetry
VIEW StateView
INVARIANT TypeOK
INVARIANT UniqueLiveIp
INVARIANT MergedNeverOwnsIdentifiers
INVARIANT MergedRedirectsSomewhere
```

`formal/dire/lifecycle_goal.cfg`:

```
CONSTANTS
  Devices = {d1, d2, d3}
  Ids = {i1, i2}
  Ips = {p1}
  NoDev = NoDev
  NoIp = NoIp
  MaxAudit = 2
  MaxWork = 1
  FollowDepth = 5
  Bugs = {}
SPECIFICATION Spec
SYMMETRY Symmetry
VIEW StateView
INVARIANT TypeOK
INVARIANT UniqueLiveIp
INVARIANT MergedNeverOwnsIdentifiers
INVARIANT MergeGraphAcyclic
INVARIANT MergedRedirectsSomewhere
INVARIANT NoStaleRedirect
PROPERTY NoZombieRevival
PROPERTY NoPurgedResurrection
PROPERTY RevivalBumpsRevision
PROPERTY UnmergeRestoresExactly
PROPERTY NoStaleCommit
```

`formal/dire/lifecycle_witness_upsert_revives_merged.cfg`:

```
CONSTANTS
  Devices = {d1, d2}
  Ids = {i1, i2}
  Ips = {p1}
  NoDev = NoDev
  NoIp = NoIp
  MaxAudit = 2
  MaxWork = 1
  FollowDepth = 5
  Bugs = {"upsert_revives_merged"}
SPECIFICATION Spec
SYMMETRY Symmetry
VIEW StateView
PROPERTY RevivalBumpsRevision
```

`formal/dire/lifecycle_witness_gateway_sync_no_bump.cfg`:

```
CONSTANTS
  Devices = {d1, d2}
  Ids = {i1, i2}
  Ips = {p1}
  NoDev = NoDev
  NoIp = NoIp
  MaxAudit = 2
  MaxWork = 1
  FollowDepth = 5
  Bugs = {"gateway_sync_no_bump"}
SPECIFICATION Spec
SYMMETRY Symmetry
VIEW StateView
PROPERTY RevivalBumpsRevision
```

`formal/dire/lifecycle_witness_follow_stale_audit.cfg`:

```
CONSTANTS
  Devices = {d1, d2}
  Ids = {i1, i2}
  Ips = {p1}
  NoDev = NoDev
  NoIp = NoIp
  MaxAudit = 2
  MaxWork = 1
  FollowDepth = 5
  Bugs = {"follow_stale_audit"}
SPECIFICATION Spec
SYMMETRY Symmetry
VIEW StateView
INVARIANT NoStaleRedirect
```

`formal/dire/lifecycle_witness_sweep_restores_merged.cfg`:

```
CONSTANTS
  Devices = {d1, d2}
  Ids = {i1, i2}
  Ips = {p1}
  NoDev = NoDev
  NoIp = NoIp
  MaxAudit = 2
  MaxWork = 1
  FollowDepth = 5
  Bugs = {"sweep_restores_merged"}
SPECIFICATION Spec
SYMMETRY Symmetry
VIEW StateView
PROPERTY NoZombieRevival
```

`formal/dire/lifecycle_witness_fence_observe_only.cfg`:

```
CONSTANTS
  Devices = {d1, d2}
  Ids = {i1, i2}
  Ips = {p1}
  NoDev = NoDev
  NoIp = NoIp
  MaxAudit = 2
  MaxWork = 1
  FollowDepth = 5
  Bugs = {"fence_observe_only"}
SPECIFICATION Spec
SYMMETRY Symmetry
VIEW StateView
PROPERTY NoStaleCommit
```

`formal/dire/lifecycle_witness_unmerge_restores_matches.cfg`:

```
CONSTANTS
  Devices = {d1, d2}
  Ids = {i1, i2}
  Ips = {p1}
  NoDev = NoDev
  NoIp = NoIp
  MaxAudit = 2
  MaxWork = 1
  FollowDepth = 5
  Bugs = {"unmerge_restores_matches"}
SPECIFICATION Spec
SYMMETRY Symmetry
VIEW StateView
PROPERTY UnmergeRestoresExactly
```

`formal/dire/lifecycle_witness_purge_forgets_redirect.cfg`:

```
CONSTANTS
  Devices = {d1, d2}
  Ids = {i1, i2}
  Ips = {p1}
  NoDev = NoDev
  NoIp = NoIp
  MaxAudit = 2
  MaxWork = 1
  FollowDepth = 5
  Bugs = {"purge_forgets_redirect"}
SPECIFICATION Spec
SYMMETRY Symmetry
VIEW StateView
PROPERTY NoPurgedResurrection
```

`formal/dire/lifecycle_witness_upsert_zombie.cfg`:

```
CONSTANTS
  Devices = {d1, d2}
  Ids = {i1, i2}
  Ips = {p1}
  NoDev = NoDev
  NoIp = NoIp
  MaxAudit = 2
  MaxWork = 1
  FollowDepth = 5
  Bugs = {"upsert_revives_merged", "fence_observe_only"}
SPECIFICATION Spec
SYMMETRY Symmetry
VIEW StateView
PROPERTY NoZombieRevival
```

`formal/dire/lifecycle_witness_merge_cycle.cfg`:

```
CONSTANTS
  Devices = {d1, d2}
  Ids = {i1, i2}
  Ips = {p1}
  NoDev = NoDev
  NoIp = NoIp
  MaxAudit = 2
  MaxWork = 1
  FollowDepth = 5
  Bugs = {"gateway_sync_no_bump", "follow_stale_audit"}
SPECIFICATION Spec
SYMMETRY Symmetry
VIEW StateView
INVARIANT MergeGraphAcyclic
```

`formal/dire/resolution_goal_armis_macs.cfg`:

```
CONSTANTS
  NoId = NoId
  NoIp = NoIp
  NoRec = NoRec
  Phys = {"h1", "h2"}
  Ifaces = {"x1", "x2"}
  IfPhys <- TwoIfPhys
  IfMac <- TwoHwMacs
  SrcOf <- BothArmis
  ArmisMacs = TRUE
  SrcIds = {"a1", "a2"}
  HwIds = {"m1", "m2"}
  LaaIds = {}
  Ips = {"p1", "p2"}
  Observers = {"Armis", "Discovery", "Arp", "Sweep"}
  Bugs = {}
SPECIFICATION Spec
INVARIANT TypeOK
INVARIANT NoFalseMerge
INVARIANT DistinctSourceIdsNeverMerge
PROPERTY EvidenceConverges
PROPERTY NoSilentDecision
```

`formal/dire/resolution_goal_armis_nomacs.cfg`:

```
CONSTANTS
  NoId = NoId
  NoIp = NoIp
  NoRec = NoRec
  Phys = {"h1", "h2"}
  Ifaces = {"x1", "x2"}
  IfPhys <- TwoIfPhys
  IfMac <- TwoHwMacs
  SrcOf <- BothArmis
  ArmisMacs = FALSE
  SrcIds = {"a1", "a2"}
  HwIds = {"m1", "m2"}
  LaaIds = {}
  Ips = {"p1", "p2"}
  Observers = {"Armis", "Discovery", "Arp", "Sweep"}
  Bugs = {}
SPECIFICATION Spec
INVARIANT TypeOK
INVARIANT NoFalseMerge
INVARIANT DistinctSourceIdsNeverMerge
PROPERTY EvidenceConverges
PROPERTY NoSilentDecision
```

`formal/dire/resolution_goal_mixed.cfg`:

```
CONSTANTS
  NoId = NoId
  NoIp = NoIp
  NoRec = NoRec
  Phys = {"h1", "h2"}
  Ifaces = {"x1", "x2"}
  IfPhys <- TwoIfPhys
  IfMac <- TwoHwMacs
  SrcOf <- OneArmis
  ArmisMacs = FALSE
  SrcIds = {"a1"}
  HwIds = {"m1", "m2"}
  LaaIds = {}
  Ips = {"p1", "p2"}
  Observers = {"Armis", "Discovery", "Arp", "Sweep"}
  Bugs = {}
SPECIFICATION Spec
INVARIANT TypeOK
INVARIANT NoFalseMerge
INVARIANT DistinctSourceIdsNeverMerge
PROPERTY EvidenceConverges
PROPERTY NoSilentDecision
```

`formal/dire/resolution_goal_router.cfg`:

```
CONSTANTS
  NoId = NoId
  NoIp = NoIp
  NoRec = NoRec
  Phys = {"h1"}
  Ifaces = {"x1", "x2"}
  IfPhys <- RouterOnlyIfPhys
  IfMac <- TwoHwMacs
  SrcOf <- NoArmis1
  ArmisMacs = FALSE
  SrcIds = {}
  HwIds = {"m1", "m2"}
  LaaIds = {}
  Ips = {"p1", "p2"}
  Observers = {"Armis", "Discovery", "Arp", "Sweep"}
  Bugs = {}
SPECIFICATION Spec
INVARIANT TypeOK
INVARIANT NoFalseMerge
INVARIANT DistinctSourceIdsNeverMerge
PROPERTY EvidenceConverges
PROPERTY NoSilentDecision
```

`formal/dire/resolution_goal_phones.cfg`:

```
CONSTANTS
  NoId = NoId
  NoIp = NoIp
  NoRec = NoRec
  Phys = {"h1", "h2"}
  Ifaces = {"x1", "x2"}
  IfPhys <- TwoIfPhys
  IfMac <- TwoLaaMacs
  SrcOf <- NoArmis2
  ArmisMacs = FALSE
  SrcIds = {}
  HwIds = {}
  LaaIds = {"r1", "r2"}
  Ips = {"p1", "p2"}
  Observers = {"Armis", "Discovery", "Arp", "Sweep"}
  Bugs = {}
SPECIFICATION Spec
INVARIANT TypeOK
INVARIANT NoFalseMerge
INVARIANT DistinctSourceIdsNeverMerge
PROPERTY EvidenceConverges
PROPERTY NoSilentDecision
```

`formal/dire/resolution_goal_armis_shared_mac.cfg`:

```
CONSTANTS
  NoId = NoId
  NoIp = NoIp
  NoRec = NoRec
  Phys = {"h1", "h2"}
  Ifaces = {"x1", "x2"}
  IfPhys <- TwoIfPhys
  IfMac <- SharedMac
  SrcOf <- BothArmis
  ArmisMacs = TRUE
  SrcIds = {"a1", "a2"}
  HwIds = {"m1"}
  LaaIds = {}
  Ips = {"p1", "p2"}
  Observers = {"Armis"}
  Bugs = {}
SPECIFICATION Spec
INVARIANT TypeOK
INVARIANT NoFalseMerge
INVARIANT DistinctSourceIdsNeverMerge
PROPERTY EvidenceConverges
PROPERTY NoSilentDecision
```

`formal/dire/resolution_witness_alias_merge_on_unknown_mac.cfg`:

```
CONSTANTS
  NoId = NoId
  NoIp = NoIp
  NoRec = NoRec
  Phys = {"h1", "h2"}
  Ifaces = {"x1", "x2"}
  IfPhys <- TwoIfPhys
  IfMac <- TwoHwMacs
  SrcOf <- BothArmis
  ArmisMacs = FALSE
  SrcIds = {"a1", "a2"}
  HwIds = {"m1", "m2"}
  LaaIds = {}
  Ips = {"p1", "p2"}
  Observers = {"Armis", "Discovery", "Arp", "Sweep"}
  Bugs = {"alias_merge_on_unknown_mac"}
SPECIFICATION Spec
INVARIANT TypeOK
INVARIANT NoFalseMerge
```

`formal/dire/resolution_witness_sync_alias_merge_unguarded.cfg`:

```
CONSTANTS
  NoId = NoId
  NoIp = NoIp
  NoRec = NoRec
  Phys = {"h1", "h2"}
  Ifaces = {"x1", "x2"}
  IfPhys <- TwoIfPhys
  IfMac <- TwoHwMacs
  SrcOf <- BothArmis
  ArmisMacs = TRUE
  SrcIds = {"a1", "a2"}
  HwIds = {"m1", "m2"}
  LaaIds = {}
  Ips = {"p1", "p2"}
  Observers = {"Armis", "Discovery", "Arp", "Sweep"}
  Bugs = {"sync_alias_merge_unguarded"}
SPECIFICATION Spec
INVARIANT TypeOK
INVARIANT NoFalseMerge
```

`formal/dire/resolution_witness_mac_only_conflicts_blocked.cfg`:

```
CONSTANTS
  NoId = NoId
  NoIp = NoIp
  NoRec = NoRec
  Phys = {"h1"}
  Ifaces = {"x1", "x2"}
  IfPhys <- RouterOnlyIfPhys
  IfMac <- TwoHwMacs
  SrcOf <- NoArmis1
  ArmisMacs = FALSE
  SrcIds = {}
  HwIds = {"m1", "m2"}
  LaaIds = {}
  Ips = {"p1", "p2"}
  Observers = {"Armis", "Discovery", "Arp", "Sweep"}
  Bugs = {"mac_only_conflicts_blocked"}
SPECIFICATION Spec
INVARIANT TypeOK
PROPERTY EvidenceConverges
```

`formal/dire/resolution_witness_silent_blocks.cfg`:

```
CONSTANTS
  NoId = NoId
  NoIp = NoIp
  NoRec = NoRec
  Phys = {"h1", "h2"}
  Ifaces = {"x1", "x2"}
  IfPhys <- TwoIfPhys
  IfMac <- TwoHwMacs
  SrcOf <- BothArmis
  ArmisMacs = FALSE
  SrcIds = {"a1", "a2"}
  HwIds = {"m1", "m2"}
  LaaIds = {}
  Ips = {"p1", "p2"}
  Observers = {"Armis", "Discovery", "Arp", "Sweep"}
  Bugs = {"silent_blocks"}
SPECIFICATION Spec
INVARIANT TypeOK
PROPERTY NoSilentDecision
```

`formal/dire/resolution_witness_src_attach_via_mac.cfg`:

```
CONSTANTS
  NoId = NoId
  NoIp = NoIp
  NoRec = NoRec
  Phys = {"h1", "h2"}
  Ifaces = {"x1", "x2"}
  IfPhys <- TwoIfPhys
  IfMac <- SharedMac
  SrcOf <- BothArmis
  ArmisMacs = TRUE
  SrcIds = {"a1", "a2"}
  HwIds = {"m1"}
  LaaIds = {}
  Ips = {"p1", "p2"}
  Observers = {"Armis"}
  Bugs = {"src_attach_via_mac"}
SPECIFICATION Spec
INVARIANT TypeOK
INVARIANT DistinctSourceIdsNeverMerge
```

`formal/dire/resolution_vacuity_router_merges.cfg`:

```
CONSTANTS
  NoId = NoId
  NoIp = NoIp
  NoRec = NoRec
  Phys = {"h1"}
  Ifaces = {"x1", "x2"}
  IfPhys <- RouterOnlyIfPhys
  IfMac <- TwoHwMacs
  SrcOf <- NoArmis1
  ArmisMacs = FALSE
  SrcIds = {}
  HwIds = {"m1", "m2"}
  LaaIds = {}
  Ips = {"p1", "p2"}
  Observers = {"Armis", "Discovery", "Arp", "Sweep"}
  Bugs = {}
SPECIFICATION Spec
INVARIANT TypeOK
INVARIANT NeverMerged
```

`formal/dire/resolution_vacuity_armis_converges.cfg`:

```
CONSTANTS
  NoId = NoId
  NoIp = NoIp
  NoRec = NoRec
  Phys = {"h1", "h2"}
  Ifaces = {"x1", "x2"}
  IfPhys <- TwoIfPhys
  IfMac <- TwoHwMacs
  SrcOf <- BothArmis
  ArmisMacs = TRUE
  SrcIds = {"a1", "a2"}
  HwIds = {"m1", "m2"}
  LaaIds = {}
  Ips = {"p1", "p2"}
  Observers = {"Armis", "Discovery", "Arp", "Sweep"}
  Bugs = {}
SPECIFICATION Spec
INVARIANT TypeOK
INVARIANT NeverConverged
```

- [ ] **Step 4: Write the targets and run on RBE**

`formal/dire/BUILD.bazel`:

```starlark
load("//build/tla:tlc.bzl", "tlc_test")

# DIRE formal models. See README.md, openspec/changes/add-dire-formal-model and
# openspec/changes/update-dire-strong-identity-goal.

tlc_test(
    name = "lifecycle_current_test",
    size = "medium",
    cfg = "lifecycle_current.cfg",
    spec = "MCDireLifecycle.tla",
    workers = 8,
    deps = ["DireLifecycle.tla"],
)

tlc_test(
    name = "lifecycle_goal_test",
    size = "medium",
    cfg = "lifecycle_goal.cfg",
    spec = "MCDireLifecycle.tla",
    workers = 8,
    deps = ["DireLifecycle.tla"],
)

tlc_test(
    name = "lifecycle_witness_upsert_revives_merged_test",
    cfg = "lifecycle_witness_upsert_revives_merged.cfg",
    expect = "violation:RevivalBumpsRevision",
    spec = "MCDireLifecycle.tla",
    deps = ["DireLifecycle.tla"],
)

tlc_test(
    name = "lifecycle_witness_gateway_sync_no_bump_test",
    cfg = "lifecycle_witness_gateway_sync_no_bump.cfg",
    expect = "violation:RevivalBumpsRevision",
    spec = "MCDireLifecycle.tla",
    deps = ["DireLifecycle.tla"],
)

tlc_test(
    name = "lifecycle_witness_follow_stale_audit_test",
    cfg = "lifecycle_witness_follow_stale_audit.cfg",
    expect = "violation:NoStaleRedirect",
    spec = "MCDireLifecycle.tla",
    deps = ["DireLifecycle.tla"],
)

tlc_test(
    name = "lifecycle_witness_sweep_restores_merged_test",
    cfg = "lifecycle_witness_sweep_restores_merged.cfg",
    expect = "violation:NoZombieRevival",
    spec = "MCDireLifecycle.tla",
    deps = ["DireLifecycle.tla"],
)

tlc_test(
    name = "lifecycle_witness_fence_observe_only_test",
    cfg = "lifecycle_witness_fence_observe_only.cfg",
    expect = "violation:NoStaleCommit",
    spec = "MCDireLifecycle.tla",
    deps = ["DireLifecycle.tla"],
)

tlc_test(
    name = "lifecycle_witness_unmerge_restores_matches_test",
    cfg = "lifecycle_witness_unmerge_restores_matches.cfg",
    expect = "violation:UnmergeRestoresExactly",
    spec = "MCDireLifecycle.tla",
    deps = ["DireLifecycle.tla"],
)

tlc_test(
    name = "lifecycle_witness_purge_forgets_redirect_test",
    cfg = "lifecycle_witness_purge_forgets_redirect.cfg",
    expect = "violation:NoPurgedResurrection",
    spec = "MCDireLifecycle.tla",
    deps = ["DireLifecycle.tla"],
)

tlc_test(
    name = "lifecycle_witness_upsert_zombie_test",
    cfg = "lifecycle_witness_upsert_zombie.cfg",
    expect = "violation:NoZombieRevival",
    spec = "MCDireLifecycle.tla",
    deps = ["DireLifecycle.tla"],
)

tlc_test(
    name = "lifecycle_witness_merge_cycle_test",
    cfg = "lifecycle_witness_merge_cycle.cfg",
    expect = "violation:MergeGraphAcyclic",
    spec = "MCDireLifecycle.tla",
    deps = ["DireLifecycle.tla"],
)

tlc_test(
    name = "resolution_goal_armis_macs_test",
    size = "medium",
    cfg = "resolution_goal_armis_macs.cfg",
    spec = "MCDireResolution.tla",
    workers = 8,
    deps = ["DireResolution.tla"],
)

tlc_test(
    name = "resolution_goal_armis_nomacs_test",
    size = "medium",
    cfg = "resolution_goal_armis_nomacs.cfg",
    spec = "MCDireResolution.tla",
    workers = 8,
    deps = ["DireResolution.tla"],
)

tlc_test(
    name = "resolution_goal_mixed_test",
    size = "medium",
    cfg = "resolution_goal_mixed.cfg",
    spec = "MCDireResolution.tla",
    workers = 8,
    deps = ["DireResolution.tla"],
)

tlc_test(
    name = "resolution_goal_router_test",
    size = "medium",
    cfg = "resolution_goal_router.cfg",
    spec = "MCDireResolution.tla",
    workers = 8,
    deps = ["DireResolution.tla"],
)

tlc_test(
    name = "resolution_goal_phones_test",
    size = "medium",
    cfg = "resolution_goal_phones.cfg",
    spec = "MCDireResolution.tla",
    workers = 8,
    deps = ["DireResolution.tla"],
)

tlc_test(
    name = "resolution_goal_armis_shared_mac_test",
    size = "medium",
    cfg = "resolution_goal_armis_shared_mac.cfg",
    spec = "MCDireResolution.tla",
    workers = 8,
    deps = ["DireResolution.tla"],
)

tlc_test(
    name = "resolution_witness_alias_merge_on_unknown_mac_test",
    cfg = "resolution_witness_alias_merge_on_unknown_mac.cfg",
    expect = "violation:NoFalseMerge",
    spec = "MCDireResolution.tla",
    deps = ["DireResolution.tla"],
)

tlc_test(
    name = "resolution_witness_sync_alias_merge_unguarded_test",
    cfg = "resolution_witness_sync_alias_merge_unguarded.cfg",
    expect = "violation:NoFalseMerge",
    spec = "MCDireResolution.tla",
    deps = ["DireResolution.tla"],
)

tlc_test(
    name = "resolution_witness_mac_only_conflicts_blocked_test",
    cfg = "resolution_witness_mac_only_conflicts_blocked.cfg",
    expect = "violation:EvidenceConverges",
    spec = "MCDireResolution.tla",
    deps = ["DireResolution.tla"],
)

tlc_test(
    name = "resolution_witness_silent_blocks_test",
    cfg = "resolution_witness_silent_blocks.cfg",
    expect = "violation:NoSilentDecision",
    spec = "MCDireResolution.tla",
    deps = ["DireResolution.tla"],
)

tlc_test(
    name = "resolution_witness_src_attach_via_mac_test",
    cfg = "resolution_witness_src_attach_via_mac.cfg",
    expect = "violation:DistinctSourceIdsNeverMerge",
    spec = "MCDireResolution.tla",
    deps = ["DireResolution.tla"],
)

tlc_test(
    name = "resolution_vacuity_router_merges_test",
    cfg = "resolution_vacuity_router_merges.cfg",
    expect = "violation:NeverMerged",
    spec = "MCDireResolution.tla",
    deps = ["DireResolution.tla"],
)

tlc_test(
    name = "resolution_vacuity_armis_converges_test",
    cfg = "resolution_vacuity_armis_converges.cfg",
    expect = "violation:NeverConverged",
    spec = "MCDireResolution.tla",
    deps = ["DireResolution.tla"],
)
```

Run: `bazel test --config=remote //formal/dire/... --test_output=errors`
Expected: 24 tests PASS. Record durations of the `medium` targets from
`bazel test --config=remote //formal/dire/... --nocache_test_results 2>&1 | grep -E "PASSED|FAILED"`.

- [ ] **Step 5: Commit**

```bash
git add formal/dire
git -c user.email=mfreeman@carverauto.dev -c user.name="Michael Freeman" commit -m "test(dire): model identity resolution and lifecycle in TLA+ with defect witnesses

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Prove the lifecycle must-pass invariants can fail (local only)

The resolution model's properties are already shown to fail by its witnesses and vacuity tests.
For the lifecycle invariants checked in `lifecycle_current`, break the model once each, run
`bazel test --config=remote //formal/dire:lifecycle_goal_test --nocache_test_results --test_output=errors`,
confirm it FAILS naming the invariant, then `git checkout formal/dire/DireLifecycle.tla`:

| Invariant | Deliberate break in `DireLifecycle.tla` |
|---|---|
| `UniqueLiveIp` | in `CommitWork`, delete the conjunct `/\ IpFreeFor(t, newIp)` |
| `MergedNeverOwnsIdentifiers` | in `Merge`, replace the `owner'` conjunct with `/\ owner' = owner` |
| `MergedRedirectsSomewhere` | in `FollowsFrom`, change `reason[u] = "merged"` in the tomb branch to `reason[u] = "other"` |
| `MergeGraphAcyclic` | in `Merge`, delete the conjunct `Live(t)` |

Copy each FAIL line into the PR description under "Invariants can fail".

---

### Task 3: Documentation

**Files:**
- Create: `formal/dire/README.md` (ASCII only)
- Modify: `openspec/changes/add-dire-formal-model/design.md`, `tasks.md`
- Modify: `openspec/changes/update-dire-strong-identity-goal/tasks.md`

- [ ] **Step 1: `formal/dire/README.md`**: what each model checks and against which requirement
  (link the goal change); the configuration kinds (goal, witness, current, vacuity); the switch
  table above; each resolution environment and the real situation it stands for (Armis with and
  without MACs, mixed Armis and network discovery, a multi-interface router, randomized-MAC
  phones, two Armis devices sharing a MAC); the fix loop (fix the code, the PR 3 trace test
  fails, remove the switch, delete its witness, add the property to the goal and current
  configurations); the abstractions and what they cannot express (numeric revision reuse after
  purge; provisional topology sightings; alias confirmation thresholds); how to run deeper
  bounds locally.
- [ ] **Step 2: `add-dire-formal-model/design.md`**: add D8 "Two models" (resolution against
  ground truth; lifecycle), replace the D2 switch table with the table above, replace D4's
  `rev`/`clock` state with the `bumped`/`stale`/`recent` abstractions and why, and state that
  the goal requirements live in `update-dire-strong-identity-goal`.
- [ ] **Step 3: tasks**: mark `add-dire-formal-model` 2.1-2.5 and 4.1 done; mark
  `update-dire-strong-identity-goal` 2.1-2.2 done and fill section 3 with one line per switch.
- [ ] **Step 4: Commit** the docs, this plan, and the goal change's design update.

---

### Task 4: Gates and the no-mistakes pipeline

- [ ] **Step 1:** `bazel test --config=remote //formal/... //build/tla/... //build/contracts/...` -> all PASS.
- [ ] **Step 2:** `make test` -> exit 0; the 24 `//formal/dire` targets appear as PASSED.
- [ ] **Step 3:** `buildifier -mode=check -lint=warn formal/dire/BUILD.bazel` -> exit 0.
- [ ] **Step 4:** Hand-check both OpenSpec changes against the strict rules (SHALL/MUST on each
  requirement's first line, a scenario per requirement), since `sfw` and `openspec` are not
  installed locally.
- [ ] **Step 5:** `no-mistakes axi run --intent "<the user's goal and decisions>"`; relay any
  `ask-user` finding verbatim; loop to an outcome.
- [ ] **Step 6:** After merge, verify by content, then file one GitHub issue per switch citing
  its witness configuration and counterexample, describing the failure mode by class.
