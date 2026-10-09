--------------------------- MODULE DireLifecycle ---------------------------
(***************************************************************************)
(* The DIRE device lifecycle as the Elixir code implements it today.        *)
(* See openspec/specs/dire-formal-model; the design is D1-D8 in             *)
(* openspec/changes/archive/2026-09-24-add-dire-formal-model/design.md, and *)
(* D5, D6, D10-D13 in openspec/changes/archive/2026-10-08-add-source-id-succession/design.md.  *)
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
    MacIds,       \* the hardware MACs among Ids; every other identifier is a source or agent id
    Ips,          \* addresses
    NoDev, NoIp,  \* "none" markers
    Bugs,         \* enabled defect switches, a subset of KnownBugs
    MaxAudit,     \* bound on merge_audit rows
    MaxWork,      \* bound on in-flight resolve->write items
    FollowDepth,      \* Resolver @max_canonical_follow_depth
    ExpiryEnabled,    \* DeviceCleanupSettings ephemeral_expiry_enabled
    RetirementEnabled \* DeviceCleanupSettings source_retirement_enabled

KnownBugs == {}

ASSUME Bugs \subseteq KnownBugs
ASSUME NoDev \notin Devices /\ NoIp \notin Ips
ASSUME MacIds \subseteq Ids
ASSUME FollowDepth \in Nat /\ MaxAudit \in Nat /\ MaxWork \in Nat
ASSUME ExpiryEnabled \in BOOLEAN /\ RetirementEnabled \in BOOLEAN

Bug(b) == b \in Bugs

Statuses == {"absent", "live", "tomb", "purged"}
\* deleted_reason classes: "merged" (MergeEngine), "expired" (EphemeralDeviceExpiry's
\* "stale_ephemeral"), "source_retired" (the grace delete of a record whose source ids all
\* retired), "seed_released" (a seed whose only address an identified record took; the
\* resolution model checks that path, and no lifecycle action writes it), and "other"
\* (administrative and remediation deletes).
Reasons  == {"none", "merged", "other", "expired", "source_retired", "seed_released"}
\* Merge callers, by how they fill merge_audit.details.identifiers (ids):
\*   "conflict" -> MergeEngine.merge_conflicting_devices/4: a list of BOTH sides' matches
\*   "auto"     -> Registrar (a map), AliasGuard, Resolver/BatchResolver MAC sibling,
\*                 DuplicateSweep: no list
\*   "manual"   -> an administrative merge: bypasses merge_guard_violation/4
\* Every kind also records the source's own identifiers (details.source_identifiers,
\* srcIds), written by do_merge_devices/5 itself.
MergeKinds == {"conflict", "auto", "manual"}
ActNames == {"Init", "StartWork", "Commit", "CommitDropped", "Reactivate", "Merge", "Unmerge",
             "SoftDelete", "Expire", "SweepCreate", "SweepRestore", "SweepRefresh", "SweepSkip",
             "GatewaySync", "Purge", "Tick", "Retire", "GraceDelete"}
\* The steps of a sweep that matched an existing row.
SweepMatchActs == {"SweepRestore", "SweepRefresh", "SweepSkip"}
\* Tombstones only an operator or the return of a retired source id may restore.
Retained == {"source_retired", "seed_released"}

VARIABLES
    status,  \* ocsf_devices row: absent (never written), live, tomb (deleted_at set), purged
    reason,  \* deleted_reason class of the last tombstone; kept after a purge
    owner,   \* device_identifiers: identifier -> owning uid (unique index => a function)
    ipOf,    \* ocsf_devices.ip; a tombstone keeps it
    audit,   \* merge_audit rows, oldest first
    work,    \* in-flight ingest items: the uid resolved, and whether its revision moved since
    marked,  \* live uids with source_retired_at set: every source and agent id they held has gone
    arch,    \* device_identifier_archive: identifier -> the uids it retired from, a row each
    sweepOnly, \* uids whose discovery_sources hold only "sweep"
    act      \* the last step, for action properties and trace validation

vars == <<status, reason, owner, ipOf, audit, work, marked, arch, sweepOnly, act>>

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
    /\ marked \subseteq Devices
    /\ arch \in [Ids -> SUBSET Devices]
    /\ sweepOnly \subseteq Devices
    /\ act \in Act

---------------------------------------------------------------------------
Live(u)       == status[u] = "live"
MergedTomb(u) == status[u] = "tomb" /\ reason[u] = "merged"
Owned(u)      == {i \in Ids : owner[i] = u}
\* The identifiers that keep a record from being marked source_retired and whose registration
\* clears the mark: every one but a MAC (SourceRetirement.marking_identifier_types/0, and the
\* trigger trg_device_identifiers_clear_source_retired).
Counted(u)    == Owned(u) \ MacIds

\* A bump of the uids in B marks every in-flight item targeting one of them stale.
MarkStale(W, B) == {[target |-> w.target, stale |-> w.stale \/ w.target \in B] : w \in W}

\* ocsf_devices_unique_active_ip_idx covers live rows only; NoIp is always free.
\* CommitWork revivals take only the incoming p (see newIp), so the active-IP precheck
\* drops a contested stored address to NoIp before the write and the index is never hit.
\* Unmerge and Restore still gate on the tombstone's stored address via this predicate.
IpFreeFor(u, p) == p = NoIp \/ ~\E d \in Devices : d # u /\ Live(d) /\ ipOf[d] = p

\* MergeAudit read :merged_to -- from_device_id = u, reason != "unmerge", newest first.
MergeRows(u) == {k \in 1..Len(audit) : audit[k].from = u /\ audit[k].kind = "merge"}
LatestMergeRow(u) ==
    IF MergeRows(u) = {} THEN 0
    ELSE CHOOSE k \in MergeRows(u) : \A j \in MergeRows(u) : j <= k
LatestMergeTarget(u) == IF LatestMergeRow(u) = 0 THEN NoDev ELSE audit[LatestMergeRow(u)].to

\* Resolver.do_follow_canonical/3 follows u when Device.get_by_uid(u, true) returns a
\* tombstone whose deleted_reason is "merged" and a merge row names a target. A purged
\* uid has no row; it is followed when its newest merge row was not reversed by an unmerge
\* (details.original_merge_event_id), which is what reason[u] = "merged" records here.
FollowsFrom(u) ==
    /\ LatestMergeTarget(u) # NoDev
    /\ LatestMergeTarget(u) # u
    /\ \/ status[u] = "tomb" /\ reason[u] = "merged"
       \/ status[u] = "purged" /\ reason[u] = "merged"

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
    /\ marked = {}
    /\ arch = [i \in Ids |-> {}]
    /\ sweepOnly = {}
    /\ act = MkAct("Init", NoDev, NoDev, 0, FALSE, {})

\* Resolver.resolve_device_identity/2: an ingest source carrying uid u resolves it,
\* following merges, and pins the revision it saw.
StartWork(u) ==
    /\ Cardinality(work) < MaxWork
    /\ work' = work \cup {[target |-> Follow(u), stale |-> FALSE]}
    /\ act' = MkAct("StartWork", u, Follow(u), 0, FALSE, {})
    /\ UNCHANGED <<status, reason, owner, ipOf, audit, marked, arch, sweepOnly>>

\* DeviceWrites insert_all(on_conflict: device_upsert_update_query(), conflict_target: [:uid])
\* plus identifier registration for the written uid. Any tombstone other than a merged-away
\* one is revived with an identity_revision bump. S: unowned identifiers the source reports;
\* p: the address it reports (NoIp = keep the current one for a live row; for a
\* revival it means NULL, since the tombstone's stored address may be held by a live
\* device and keeping it would fail the write on ocsf_devices_unique_active_ip_idx).
\* Retired ids (D6): S may carry an id the archive keeps for t or for a uid merged into t.
\* Reporting it again moves those archive rows back to t, and is the only write that restores
\* a source_retired tombstone. The corroboration and the one-holder rules are the resolution
\* model's; here any such write reactivates, and bumps the record it returns to whether or not
\* it was live (SourceReactivation.revive/2). A write that registers a source or agent id on a
\* marked record clears the mark, because the record is no longer retired-only; a MAC does not.
\* The upsert unions discovery_sources with the source's own, so the record it writes is no
\* longer sweep-only.
CommitWork(w, S, p) ==
    LET t     == w.target
        back  == {i \in S : \E d \in arch[i] : Follow(d) = t}
        newIp == IF status[t] = "tomb" THEN p
                 ELSE IF p = NoIp THEN ipOf[t] ELSE p
        bump  == CASE status[t] \in {"absent", "purged"} -> {t}  \* a new row
                   [] status[t] = "tomb" -> {t}                  \* a revival
                   [] back # {} -> {t}                           \* a live reactivation
                   [] OTHER -> {}
    IN
    /\ w \in work
    /\ S \subseteq {i \in Ids : owner[i] = NoDev}
    /\ UNCHANGED audit
    /\ IF w.stale
       THEN \* Identity.Fence.fenced_write/3: the batch locks its pinned device rows and
            \* finds the identity decision stale; the write is withheld and re-resolved.
            /\ work' = work \ {w}
            /\ act' = MkAct("CommitDropped", NoDev, t, 0, w.stale, {})
            /\ UNCHANGED <<status, reason, owner, ipOf, marked, arch, sweepOnly>>
       ELSE IF MergedTomb(t)
       THEN \* A merged-away uid is never written back to life: the update's WHERE skips its
            \* row, and follow_merged_away_uids/2 hands the batch's identifiers to the
            \* survivor, which the model abstracts as a drop the next StartWork re-resolves.
            /\ work' = work \ {w}
            /\ act' = MkAct("CommitDropped", NoDev, t, 0, w.stale, {})
            /\ UNCHANGED <<status, reason, owner, ipOf, marked, arch, sweepOnly>>
       ELSE IF status[t] = "tomb" /\ reason[t] \in Retained /\ back = {}
       THEN \* An evidence sighting of a source_retired or seed_released tombstone (an
            \* address-only or MAC-only match, or a source that reports none of its retired
            \* ids): the upsert's WHERE skips the row, as for a merged-away one (D5).
            /\ work' = work \ {w}
            /\ act' = MkAct("CommitDropped", NoDev, t, 0, w.stale, {})
            /\ UNCHANGED <<status, reason, owner, ipOf, marked, arch, sweepOnly>>
       ELSE
            /\ IpFreeFor(t, newIp)
            /\ ipOf' = [ipOf EXCEPT ![t] = newIp]
            /\ status' = [status EXCEPT ![t] = "live"]
            /\ reason' = [reason EXCEPT ![t] = "none"]
            /\ owner' = [i \in Ids |-> IF i \in S THEN t ELSE owner[i]]
            /\ arch' = [i \in Ids |-> IF i \in back THEN {d \in arch[i] : Follow(d) # t}
                                                 ELSE arch[i]]
            /\ marked' = IF S \ MacIds # {} THEN marked \ {t} ELSE marked
            /\ sweepOnly' = sweepOnly \ {t}
            /\ work' = MarkStale(work \ {w}, bump)
            /\ act' = MkAct(IF back # {} THEN "Reactivate" ELSE "Commit", NoDev, t, 0, w.stale, bump)

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
    \* A merged-away record is no longer marked; a marked survivor that takes a source or agent
    \* id from the other record (a source_succession merge, D3) is no longer retired-only.
    /\ marked' = marked \ ({f} \cup (IF Counted(f) # {} THEN {t} ELSE {}))
    \* The survivor takes the union of both records' discovery_sources.
    /\ sweepOnly' = IF f \in sweepOnly THEN sweepOnly ELSE sweepOnly \ {t}
    /\ work' = MarkStale(work, {f, t})
    /\ act' = MkAct("Merge", f, t, Len(audit) + 1, FALSE, {f, t})
    /\ UNCHANGED <<ipOf, arch>>

\* MergeEngine.unmerge_device/2 -> do_unmerge/4. recreate_device/3 restores a tombstone of
\* any reason (:restore bumps), leaves a live row alone, or inserts a missing one;
\* reassign_original_identifiers/4 moves back the identifiers the survivor still holds
\* that the source owned when it was merged (details.source_identifiers); the survivor
\* must be live. A restored tombstone is not marked, because a delete clears the mark; a live
\* record keeps its mark unless a source or agent id moves back to it.
Unmerge(u) ==
    LET k    == LatestMergeRow(u)
        row  == audit[k]
        s    == row.to
        back == {i \in Ids : owner[i] = s /\ i \in row.srcIds}
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
    /\ marked' = IF back \ MacIds # {} THEN marked \ {u} ELSE marked
    /\ work' = MarkStale(work, bump)
    /\ act' = MkAct("Unmerge", u, s, k, FALSE, bump)
    /\ UNCHANGED <<ipOf, arch, sweepOnly>>

\* Device :soft_delete (administrative and remediation deletes; deleted_reason /= "merged").
SoftDelete(u) ==
    /\ Live(u)
    /\ status' = [status EXCEPT ![u] = "tomb"]
    /\ reason' = [reason EXCEPT ![u] = "other"]
    /\ marked' = marked \ {u}
    /\ work' = MarkStale(work, {u})
    /\ act' = MkAct("SoftDelete", u, NoDev, 0, FALSE, {u})
    /\ UNCHANGED <<owner, ipOf, audit, arch, sweepOnly>>

\* EphemeralDeviceExpiry.run/3 (DeviceCleanupWorker, #4603): a live device unseen past the
\* expiry window that holds no strong identifier is soft-deleted (deleted_reason
\* "stale_ephemeral", a non-merge reason). Every identifier in this model is strong, a MAC in
\* MacIds included (randomized MACs and addresses are evidence and are not in Ids), so only a
\* device owning none is eligible. The check is platform.device_holds_strong_identifier/1
\* inside the soft delete's UPDATE ... WHERE, so selection and delete are one step. Last-seen
\* time is not modeled: any eligible live device may expire. The pass runs only when
\* ephemeral_expiry_enabled is set.
\* A record whose source id retired still carries it in its metadata, and the pass's
\* in-memory check (strong_attributes?/1) holds it: the grace delete, not expiry, removes a
\* retired-only record (D13).
Expire(u) ==
    /\ ExpiryEnabled
    /\ Live(u)
    /\ Owned(u) = {}
    /\ \A i \in Ids : u \notin arch[i]
    /\ status' = [status EXCEPT ![u] = "tomb"]
    /\ reason' = [reason EXCEPT ![u] = "expired"]
    /\ work' = MarkStale(work, {u})
    /\ act' = MkAct("Expire", u, NoDev, 0, FALSE, {u})
    /\ UNCHANGED <<owner, ipOf, audit, marked, arch, sweepOnly>>

\* SweepResultsIngestor.ingest_results/3 for an address p that answered. DeviceLookup
\* (include_deleted: true) prefers the live holder of p and otherwise falls back to a tombstone;
\* which tombstone wins is left nondeterministic. restore_deleted_devices/3 then restores the
\* match through :restore (which bumps) when the code allows it:
\*  - a merged-away tombstone never: eligible_restore_uids/2 skips it and records the skip;
\*  - a source_retired or seed_released tombstone never (D5);
\*  - an expired tombstone always, whatever its sources (D12);
\*  - any other tombstone only when restore_eligible?/1 finds a discovery source other than
\*    "sweep".
\* update_device_statuses_available/3 then writes the sighting, to a live record only
\* (deleted_at IS NULL): a live match takes it (SweepRefresh), and an unrestored tombstone is left
\* exactly as it was (SweepSkip). Availability and last_seen_time are not state here, so neither
\* step changes a modeled variable, and the appended "sweep" discovery source changes no record's
\* sweep-only flag. A sweep that finds the address down is not modeled: it restores only a
\* tombstone an answering sweep restores too, never an expired one, and its hysteresis write
\* lands on a live record only, so it reaches no state an answering sweep does not.
\* (The former event_writer/processors/sweep.ex carried a copy of this path but was
\* unregistered and has been removed, so it never ran; the live sweep path is
\* sweep_jobs/sweep_results_ingestor.ex.)
SweepMatch(p, d) ==
    /\ ipOf[d] = p
    /\ IF \E e \in Devices : Live(e) /\ ipOf[e] = p THEN Live(d) ELSE status[d] = "tomb"

SweepRestorable(d) ==
    /\ status[d] = "tomb"
    /\ reason[d] \notin {"merged"} \cup Retained
    /\ \/ d \notin sweepOnly
       \/ reason[d] = "expired"

Sweep(p, d) ==
    /\ SweepMatch(p, d)
    /\ IF SweepRestorable(d)
       THEN /\ status' = [status EXCEPT ![d] = "live"]
            /\ reason' = [reason EXCEPT ![d] = "none"]
            /\ work' = MarkStale(work, {d})
            /\ act' = MkAct("SweepRestore", d, NoDev, 0, FALSE, {d})
       ELSE /\ act' = MkAct(IF Live(d) THEN "SweepRefresh" ELSE "SweepSkip",
                            d, NoDev, 0, FALSE, {})
            /\ UNCHANGED <<status, reason, work>>
    /\ UNCHANGED <<owner, ipOf, audit, marked, arch, sweepOnly>>

\* SweepResultsIngestor.create_available_unknown_devices/5: an address no row holds, live or
\* deleted, gets a new seed with discovery_sources ["sweep"] and no identifier. Its uid comes from
\* the address (IdentityReconciler.generate_deterministic_device_id/1), and a duplicate create is
\* skipped. A uid that redirects to a merge survivor gives way to the next uid of the chain
\* Ids.reseeded_device_id/1 derives (task 9.7), so a purged merged-away record is never written
\* live again, and the model creates only a row that never existed. (The code re-creates under
\* its own uid a purged record nothing redirects, one never merged away or whose merge an
\* unmerge reversed; the model seeds a record that never existed instead.)
SweepCreate(p, d) ==
    /\ ~\E e \in Devices : status[e] \in {"live", "tomb"} /\ ipOf[e] = p
    /\ status[d] = "absent"
    /\ status' = [status EXCEPT ![d] = "live"]
    /\ ipOf' = [ipOf EXCEPT ![d] = p]
    /\ sweepOnly' = sweepOnly \cup {d}
    /\ work' = MarkStale(work, {d})
    /\ act' = MkAct("SweepCreate", d, NoDev, 0, FALSE, {d})
    /\ UNCHANGED <<reason, owner, audit, marked, arch>>

\* AgentGatewaySync.upsert_device_for_agent/4 on the agent's device uid: a soft-deleted device
\* is restored through Device :gateway_restore, which bumps identity_revision as :restore
\* does. A merged-away device is never revived: follow_merged_away_device/6 writes the
\* check-in to the survivor (an ordinary write to a live device, outside this action).
\* :gateway_restore honors a source_retired or seed_released reason as well (D5). The agent's
\* discovery source joins discovery_sources, so the record is no longer sweep-only.
GatewaySync(u) ==
    /\ status[u] = "tomb" /\ IpFreeFor(u, ipOf[u])
    /\ reason[u] \notin {"merged"} \cup Retained
    /\ status' = [status EXCEPT ![u] = "live"]
    /\ reason' = [reason EXCEPT ![u] = "none"]
    /\ work' = MarkStale(work, {u})
    /\ sweepOnly' = sweepOnly \ {u}
    /\ act' = MkAct("GatewaySync", u, NoDev, 0, FALSE, {u})
    /\ UNCHANGED <<owner, ipOf, audit, marked, arch>>

\* DeviceCleanupWorker.hard_delete_records/2: the row and its device_identifiers go;
\* merge_audit and device_identifier_archive rows stay. reason is kept: after a purge it
\* stands for what merge_audit still says, whether the uid's newest merge row is an
\* unreversed merge.
Purge(u) ==
    /\ status[u] = "tomb"
    /\ status' = [status EXCEPT ![u] = "purged"]
    /\ owner' = [i \in Ids |-> IF owner[i] = u THEN NoDev ELSE owner[i]]
    /\ ipOf' = [ipOf EXCEPT ![u] = NoIp]
    /\ sweepOnly' = sweepOnly \ {u}
    /\ work' = MarkStale(work, {u})
    /\ act' = MkAct("Purge", u, NoDev, 0, FALSE, {u})
    /\ UNCHANGED <<reason, audit, marked, arch>>

\* The merge cooldown window (merge_cooldown_seconds, default 86_400) elapses.
Tick ==
    /\ \E k \in 1..Len(audit) : audit[k].recent
    /\ audit' = [k \in 1..Len(audit) |-> [audit[k] EXCEPT !.recent = FALSE]]
    /\ act' = MkAct("Tick", NoDev, NoDev, 0, FALSE, {})
    /\ UNCHANGED <<status, reason, owner, ipOf, work, marked, arch, sweepOnly>>

\* The retirement of source ids R that u holds (D1): each row moves to
\* device_identifier_archive in one transaction, which bumps u's identity_revision
\* (SourceRetirement.archive/4). A MAC never retires. If u then holds no source or agent id, the
\* same transaction marks it source_retired (D5); the MACs it holds stay with it. The absence
\* count, the minimum absence and the mass guard are the resolution model's, as are the
\* conditions on agent and other-type ids, recent identity-bearing observations and
\* operator-created records, which only ever withhold a mark; here any source or agent id a live
\* record holds may retire, and every identifier counts as current until it does.
Retire(u, R) ==
    /\ RetirementEnabled
    /\ Live(u)
    /\ R # {} /\ R \subseteq Counted(u)
    /\ owner' = [i \in Ids |-> IF i \in R THEN NoDev ELSE owner[i]]
    /\ arch' = [i \in Ids |-> IF i \in R THEN arch[i] \cup {u} ELSE arch[i]]
    /\ marked' = IF R = Counted(u) THEN marked \cup {u} ELSE marked
    /\ work' = MarkStale(work, {u})
    /\ act' = MkAct("Retire", u, NoDev, 0, FALSE, {u})
    /\ UNCHANGED <<status, reason, ipOf, audit, sweepOnly>>

\* DeviceCleanupWorker's grace pass (D5): a record marked for the grace period is soft-deleted
\* through Device :soft_delete with deleted_reason "source_retired", and the same transaction
\* releases its address; the MACs it holds stay with the tombstone. The open-review hold and the
\* mass guard only ever refuse, so they are left nondeterministic, and elapsed time is not
\* modeled: any marked record may be deleted.
GraceDelete(u) ==
    /\ u \in marked
    /\ status' = [status EXCEPT ![u] = "tomb"]
    /\ reason' = [reason EXCEPT ![u] = "source_retired"]
    /\ ipOf' = [ipOf EXCEPT ![u] = NoIp]
    /\ marked' = marked \ {u}
    /\ work' = MarkStale(work, {u})
    /\ act' = MkAct("GraceDelete", u, NoDev, 0, FALSE, {u})
    /\ UNCHANGED <<owner, audit, arch, sweepOnly>>

Next ==
    \/ \E u \in Devices :
         StartWork(u) \/ Unmerge(u) \/ SoftDelete(u) \/ Expire(u) \/ GatewaySync(u) \/ Purge(u)
         \/ GraceDelete(u) \/ \E R \in SUBSET Ids : Retire(u, R)
    \/ \E w \in work, S \in SUBSET Ids, p \in Ips \cup {NoIp} : CommitWork(w, S, p)
    \/ \E f, t \in Devices, kind \in MergeKinds, S \in SUBSET Ids : Merge(f, t, kind, S)
    \/ \E p \in Ips, d \in Devices : Sweep(p, d) \/ SweepCreate(p, d)
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

\* Retired Records Without A Successor (add-source-id-succession D5): a marked record is live
\* and holds no source or agent id, so the grace delete never removes a record that holds one.
\* A MAC is not evidence the source still reports the record, so a marked record may hold one.
MarkedHoldsOnlyMacs == \A u \in marked : Live(u) /\ Counted(u) = {}

NoStaleRedirect ==
    \A u \in Devices : (status[u] = "tomb" /\ reason[u] # "merged") => Follow(u) = u

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

\* Randomized MACs Are Evidence Only (update-dire-strong-identity-goal D4): expiry never removes
\* a device holding a strong identifier (#4603).
ExpiryKeepsStrongIdentity ==
    [][act'.name = "Expire" => \A i \in Ids : owner[i] # act'.u]_vars

\* Sweep Restore Of Expired Devices (add-source-id-succession D12): a sweep writes only a record
\* that is live after the step, and a sweep that matches an expired tombstone restores it.
SweepWritesOnlyLiveRecords ==
    [][act'.name \in {"SweepCreate", "SweepRestore", "SweepRefresh"}
          => status'[act'.u] = "live"]_vars

ExpiredDeviceReturns ==
    [][(act'.name \in SweepMatchActs /\ status[act'.u] = "tomb" /\ reason[act'.u] = "expired")
          => status'[act'.u] = "live"]_vars

\* Restore Soft-Deleted Devices (add-source-id-succession D5): a source_retired tombstone is
\* restored only by the return of one of its retired source ids or by an operator's unmerge;
\* no sweep, address-only or MAC-only sighting, agent check-in or other write restores it.
RetiredTombstoneStaysDeleted ==
    [][\A u \in Devices :
         (status[u] = "tomb" /\ reason[u] = "source_retired" /\ status'[u] = "live")
            => act'.name \in {"Reactivate", "Unmerge"}]_vars

=============================================================================
