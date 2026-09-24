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
    act       \* the last step's identity decisions and the records written for them

vars == <<ipAt, created, into, owner, recIp, alias, phys, act>>

\* An identity decision is a kind and the records it concerns.
DecisionKinds == {"policy_block", "source_block", "alias_invalidated", "source_override"}
Decision == [kind: DecisionKinds, recs: SUBSET Recs]

TypeOK ==
    /\ ipAt \in [Ifaces -> Ips \cup {NoIp}]
    /\ created \in [Recs -> BOOLEAN]
    /\ into \in [Recs -> Recs \cup {NoRec}]
    /\ owner \in [Ids -> Recs \cup {NoRec}]
    /\ recIp \in [Recs -> Ips \cup {NoIp}]
    /\ alias \in [Ips -> SUBSET Recs]
    /\ phys \in [Recs -> SUBSET Phys]
    /\ act \in [name: STRING, decisions: SUBSET Decision, recorded: SUBSET Decision,
                ids: SUBSET Ids]

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
    /\ act = [name |-> "Init", decisions |-> {}, recorded |-> {}, ids |-> {}]

\* DHCP: an interface leases a free address or releases its lease.
Lease(x, p) ==
    /\ p # ipAt[x]
    /\ p = NoIp \/ ~\E y \in Ifaces : ipAt[y] = p
    /\ ipAt' = [ipAt EXCEPT ![x] = p]
    /\ act' = [name |-> "Lease", decisions |-> {}, recorded |-> {}, ids |-> {}]
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
        \* Goal: address or alias evidence never merges two records; an identified holder of
        \* the alias has the alias invalidated and an address-only holder is left alone.
        \* Whether an identified device absorbs a provisional address-only record is an open
        \* question in openspec/changes/update-dire-strong-identity-goal/design.md.
        \* AliasGuard (Resolver path): merge unless both hold MACs and they are disjoint;
        \* MergeEngine's source-authority guard still blocks disjoint Armis ids.
        \* Sync.Aliases (sync path): merge unless the source-authority guard blocks it; no
        \* MAC veto at all, and no invalidation unless the agent guard fires.
        aliasMerge(y) ==
            IF syncAlias /\ Bug("sync_alias_merge_unguarded") THEN ~SrcConflictIn(owner1, {y, target})
            ELSE IF ~syncAlias /\ Bug("alias_merge_on_unknown_mac")
            THEN ~DistinctMacs(y, target) /\ ~SrcConflict({y, target})
            ELSE FALSE                \* goal: address evidence never merges
        aliasInvalidate(y) ==
            IF syncAlias /\ Bug("sync_alias_merge_unguarded") THEN FALSE
            ELSE IF ~syncAlias /\ Bug("alias_merge_on_unknown_mac") THEN DistinctMacs(y, target)
            ELSE IdsHeld(y) # {}
        \* AliasGuard runs only on the strong-match branch; Sync.Aliases runs for every
        \* resolved sync update, including one that created its device.
        aliasRuns   == M # {} \/ syncAlias
        step2Merged == IF aliasRuns THEN {y \in aliasY : aliasMerge(y)} ELSE {}
        step2Inval  == IF aliasRuns THEN {y \in aliasY : aliasInvalidate(y)} ELSE {}
        merged == step1Merged \cup step2Merged
        \* Every decision this step makes. A MergePolicy or AliasGuard refusal reaches telemetry
        \* only under silent_blocks; a source-authority refusal (SourceAuthorityGuard.record_blocked/3)
        \* and the goal's source-authoritative override are always recorded.
        ownerGuard == IF syncAlias THEN owner1 ELSE owner
        srcRefused == {y \in aliasY \ (step2Merged \cup step2Inval) :
                         aliasRuns /\ SrcConflictIn(ownerGuard, {y, target})}
        decisions ==
            (IF others # {} /\ ~conflictOk
             THEN {[kind |-> IF SrcConflict(M) THEN "source_block" ELSE "policy_block", recs |-> M]}
             ELSE {})
            \cup {[kind |-> "alias_invalidated", recs |-> {y, target}] : y \in step2Inval}
            \cup {[kind |-> "source_block", recs |-> {y, target}] : y \in srcRefused}
            \cup (IF allM \ M # {}
                  THEN {[kind |-> "source_override", recs |-> (allM \ M) \cup {target}]}
                  ELSE {})
        recorded == {d \in decisions :
                       d.kind \in {"source_block", "source_override"} \/ ~Bug("silent_blocks")}
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
    /\ act' = [name |-> kind, decisions |-> decisions, recorded |-> recorded, ids |-> S]
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
NoSilentDecision == [][act'.decisions \subseteq act'.recorded]_vars

=============================================================================
