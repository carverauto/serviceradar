--------------------------- MODULE DireResolution ---------------------------
(***************************************************************************)
(* DIRE identity resolution against physical ground truth.                  *)
(* See openspec/changes/update-dire-strong-identity-goal (the requirements) *)
(* and openspec/specs/dire-formal-model (the verification).                 *)
(*                                                                          *)
(* The world: physical devices own interfaces; an interface has a true MAC  *)
(* (hardware or randomized) and leases an address, and DHCP moves addresses *)
(* between interfaces. Observers report what they would really see, and     *)
(* each observer follows the real ingestion path it models:                 *)
(*   Armis   -> SyncIngestor (BatchResolver, DeviceWrites, Sync.Aliases)    *)
(*   Arp     -> netprobe census -> SyncIngestor (no alias merge)            *)
(*   Agent   -> AgentGatewaySync -> Resolver (AliasGuard)                   *)
(*   Mapper  -> MapperResultsIngestor (address, then alias, then DIRE)      *)
(*   Sweep   -> SweepResultsIngestor (attach, or a provisional seed)        *)
(* A ghost variable, phys, tracks which physical devices' identity-bearing  *)
(* observations went into each record, so "one record describes two        *)
(* devices" is checkable. The shape of every action was checked against    *)
(* traces recorded from the real code (formal/dire/traces).                 *)
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
    AgentOf,       \* [Phys -> AgentIds \cup {NoId}]: the agent running on the device, if any
    ArmisMacs,     \* whether Armis reports the device's MACs with its id
    AgentIds,      \* agent ids (agent_id identifiers)
    SrcIds,        \* source-authoritative identifiers (one source)
    HwIds,         \* globally-unique MACs
    LaaIds,        \* locally-administered (randomized) MACs
    Ips,
    Observers,     \* which observers exist in this environment
    NoId, NoIp, NoRec,
    Bugs

KnownBugs == {
    "alias_merge_on_unknown_mac",  \* inventory/identity/alias_guard.ex maybe_merge_ip_alias_device/3
    "mac_only_conflicts_blocked",  \* inventory/identity/merge_policy.ex mac_only_matches?/1
    "silent_blocks",               \* MergePolicy / AliasGuard decisions reach only telemetry
    "src_attach_via_mac",          \* inventory/identity/resolver.ex lookup_by_strong_identifiers/3
    "mapper_resolves_by_address",  \* network_discovery/mapper_results_ingestor.ex resolve_device_ids/2
    "stale_holder_keeps_address"   \* inventory/sync/device_writes.ex resolve_record_active_ip/7
}
ASSUME Bugs \subseteq KnownBugs

Bug(b) == b \in Bugs

MacIds == HwIds \cup LaaIds
Ids    == AgentIds \cup SrcIds \cup MacIds
\* A record is named by the seed its uid was derived from: the highest-priority identifier
\* (Ids.generate_deterministic_device_id/1) or, for an identifier-less update, the address.
Recs   == Ids \cup Ips

\* Ids @identifier_priority: agent_id, armis_device_id / integration_id, ..., mac.
Prio(i) == IF i \in AgentIds THEN 0 ELSE IF i \in SrcIds THEN 1 ELSE IF i \in HwIds THEN 2 ELSE 3
Seed(S) == CHOOSE i \in S : \A j \in S : Prio(i) <= Prio(j)

MacsOf(h) == {IfMac[x] : x \in {y \in Ifaces : IfPhys[y] = h}} \ {NoId}

VARIABLES
    ipAt,     \* ground truth: the address each interface currently leases
    created,  \* ocsf_devices row exists
    into,     \* merge redirect: NoRec while live
    owner,    \* device_identifiers: identifier -> record
    recIp,    \* ocsf_devices.ip
    alias,    \* confirmed IP aliases: address -> records
    phys,     \* ghost: physical devices whose identity-bearing observations built the record
    ifClaims, \* InterfaceMacs: interface MACs a record's own interface table claims
    act       \* the last step: observer, reported ids, address, decisions, address merges

vars == <<ipAt, created, into, owner, recIp, alias, phys, ifClaims, act>>

DecisionKinds == {"policy_block", "source_block", "alias_invalidated", "source_override",
                  "ip_conflict"}
Decision == [kind: DecisionKinds, recs: SUBSET Recs]

TypeOK ==
    /\ ipAt \in [Ifaces -> Ips \cup {NoIp}]
    /\ created \in [Recs -> BOOLEAN]
    /\ into \in [Recs -> Recs \cup {NoRec}]
    /\ owner \in [Ids -> Recs \cup {NoRec}]
    /\ recIp \in [Recs -> Ips \cup {NoIp}]
    /\ alias \in [Ips -> SUBSET Recs]
    /\ phys \in [Recs -> SUBSET Phys]
    /\ ifClaims \in [Recs -> SUBSET MacIds]
    /\ act \in [name: STRING, ids: SUBSET Ids, ip: Ips \cup {NoIp},
                decisions: SUBSET Decision, recorded: SUBSET Decision,
                addressMerged: SUBSET Recs]

Live(r) == created[r] /\ into[r] = NoRec

\* Resolver.follow_canonical_device_id/2 (correct following assumed; see DireLifecycle).
RECURSIVE CanonIn(_, _, _)
CanonIn(i, r, n) == IF n = 0 \/ i[r] = NoRec THEN r ELSE CanonIn(i, i[r], n - 1)
Canon(r) == CanonIn(into, r, Cardinality(Recs))

HeldIn(o, r, C) == {i \in C : o[i] = r}
SrcHeldIn(o, r) == HeldIn(o, r, SrcIds)
SrcHeld(r) == SrcHeldIn(owner, r)
AgentHeld(r) == HeldIn(owner, r, AgentIds)
MacsHeld(r) == HeldIn(owner, r, MacIds)
IdsHeldIn(o, r) == HeldIn(o, r, Ids)
IdsHeld(r) == IdsHeldIn(owner, r)

\* SourceAuthorityGuard.conflict_from_rows/2: two records holding disjoint, non-empty sets
\* of the same source's identifiers. Recorded (record_blocked/3).
SrcConflictIn(o, M) == \E a, b \in M : a # b /\ SrcHeldIn(o, a) # {} /\ SrcHeldIn(o, b) # {}
                                        /\ SrcHeldIn(o, a) \cap SrcHeldIn(o, b) = {}
SrcConflict(M) == SrcConflictIn(owner, M)

\* AliasGuard.distinct_agent_identity_conflict?/3; MergeEngine refuses every automatic merge of
\* such a pair (merge_guard_violation/4).
DistinctAgents(a, b) == AgentHeld(a) # {} /\ AgentHeld(b) # {} /\ AgentHeld(a) \cap AgentHeld(b) = {}

\* AliasGuard.same_chassis?/5: one record's own interface table claims a MAC the other holds.
SameChassis(a, b) == ifClaims[a] \cap MacsHeld(b) # {} \/ ifClaims[b] \cap MacsHeld(a) # {}

\* AliasGuard.distinct_mac_conflict?/3: both hold MACs, the sets are disjoint, and no chassis
\* claim links them. "Unknown is not distinct".
DistinctMacs(a, b) == MacsHeld(a) # {} /\ MacsHeld(b) # {} /\ MacsHeld(a) \cap MacsHeld(b) = {}
                      /\ ~SameChassis(a, b)

\* AliasGuard.distinct_identified_devices?/3 (#4609), on post-registration ownership o.
DistinctIdentifiedIn(o, a, b) == IdsHeldIn(o, a) # {} /\ IdsHeldIn(o, b) # {} /\ ~SameChassis(a, b)

\* MergePolicy.merge_allowed_for_matches?/1 over the identifiers that matched.
\*   today: never an all-MAC set (globally-unique MACs included), never an all-randomized set
\*   goal:  any set containing an agent, source-authoritative or globally-unique identifier
PolicyAllows(matched) ==
    IF Bug("mac_only_conflicts_blocked")
    THEN matched \cap (AgentIds \cup SrcIds) # {}
    ELSE matched \cap (AgentIds \cup SrcIds \cup HwIds) # {}

---------------------------------------------------------------------------
Init ==
    /\ ipAt = [x \in Ifaces |-> NoIp]
    /\ created = [r \in Recs |-> FALSE]
    /\ into = [r \in Recs |-> NoRec]
    /\ owner = [i \in Ids |-> NoRec]
    /\ recIp = [r \in Recs |-> NoIp]
    /\ alias = [p \in Ips |-> {}]
    /\ phys = [r \in Recs |-> {}]
    /\ ifClaims = [r \in Recs |-> {}]
    /\ act = [name |-> "Init", ids |-> {}, ip |-> NoIp, decisions |-> {}, recorded |-> {},
              addressMerged |-> {}]

\* DHCP: an interface leases a free address or releases its lease.
Lease(x, p) ==
    /\ p # ipAt[x]
    /\ p = NoIp \/ ~\E y \in Ifaces : ipAt[y] = p
    /\ ipAt' = [ipAt EXCEPT ![x] = p]
    /\ act' = [name |-> "Lease", ids |-> {}, ip |-> NoIp, decisions |-> {}, recorded |-> {},
               addressMerged |-> {}]
    /\ UNCHANGED <<created, into, owner, recIp, alias, phys, ifClaims>>

\* The phys ghost after a step: merged records' devices join the target, and an identity-bearing
\* observation joins the record it landed on -- the one now owning its identifiers, or, when they
\* are split across records, the live record holding the observed address.
PhysAfter(h, S, p, merged, target, owner2, into2, recIp2) ==
    LET canon2(r) == CanonIn(into2, r, Cardinality(Recs))
        cands == {canon2(owner2[i]) : i \in {j \in S : owner2[j] # NoRec}}
        holders == {r \in Recs : (created[r] \/ r = target) /\ into2[r] = NoRec /\ recIp2[r] = p}
        landing == IF Cardinality(cands) = 1 THEN CHOOSE r \in cands : TRUE
                   ELSE IF cands # {} /\ holders # {} THEN CHOOSE r \in holders : TRUE
                   ELSE NoRec
        base == [r \in Recs |-> IF r = target
                                THEN phys[r] \cup UNION {phys[m] : m \in merged}
                                ELSE phys[r]]
    IN [r \in Recs |-> IF S # {} /\ r = landing THEN base[r] \cup {h} ELSE base[r]]

\* One observation of physical device h at interface x's address, carrying identifiers S,
\* through the resolver and the device write.
\*   aliasPath: "none" (census), "sync" (Sync.Aliases), "guard" (AliasGuard, Resolver path)
\*   recordAlias: this update's address is recorded as a (confirmed) alias of the result
\*   claims: interface MACs the observation registers as the result's own interface table
Resolve(h, x, S, recordAlias, aliasPath, kind, claims) ==
    LET p       == ipAt[x]
        srcS    == S \cap SrcIds
        \* A matched record holding a different source-authoritative identifier than the one
        \* this update carries. Today the update attaches to it anyway: conflict detection only
        \* compares identifiers that are already owned, and this update's own id is new.
        \* Goal: the source-authoritative identifier decides; such a record is not a match.
        srcMismatch(r) == srcS # {} /\ SrcHeld(r) # {} /\ SrcHeld(r) \cap srcS = {}
        allM    == {Canon(owner[i]) : i \in {j \in S : owner[j] # NoRec}}
        M       == IF Bug("src_attach_via_mac") THEN allM ELSE {r \in allM : ~srcMismatch(r)}
        matched == {i \in S : owner[i] # NoRec /\ Canon(owner[i]) \in M}
    IN
    \E X \in (IF M # {} THEN M ELSE {NoRec}) :
    LET \* --- Step 1: strong-identifier conflict (merge_conflicting_devices/4) ---
        others     == M \ {X}
        conflictOk == others # {} /\ ~SrcConflict(M) /\ PolicyAllows(matched)
        step1Merged == IF conflictOk THEN {o \in others : ~DistinctAgents(o, X)} ELSE {}
        \* --- Fallback when nothing matched (resolve_fallback_device_id/3) ---
        holderAt == {r \in Recs : Live(r) /\ r \notin step1Merged /\ recIp[r] = p}
        target0 ==
            IF M # {} THEN X
            ELSE IF S # {} THEN Canon(Seed(S))
            ELSE LET weak == holderAt \cup {r \in alias[p] : Live(r)}
                 IN IF weak # {} THEN CHOOSE r \in weak : TRUE ELSE Canon(p)
        \* --- The device write and ocsf_devices_unique_active_ip_idx
        \*     (DeviceWrites.resolve_record_active_ip/7) ---
        others0   == holderAt \ {target0}
        seedHold  == {r \in others0 : IdsHeld(r) = {}}
        \* A strong write onto an address held by an anchorless provisional seed adopts the seed.
        adopt     == S # {} /\ ~created[target0] /\ seedHold # {}
        target    == IF adopt THEN CHOOSE r \in seedHold : TRUE ELSE target0
        holders   == holderAt \ {target}
        ipConflict == S # {} /\ holders # {}
        keepsIp   == ipConflict /\ Bug("stale_holder_keeps_address")
        owner1 == [i \in Ids |->
                     IF owner[i] \in step1Merged THEN target
                     ELSE IF i \in S /\ owner[i] = NoRec THEN target
                     ELSE owner[i]]
        \* --- Step 2: the IP-alias merge ---
        \* Goal: address or alias evidence never merges two records; an identified holder of the
        \* alias has the alias invalidated and an address-only holder is left alone.
        aliasY == {y \in alias[p] : Live(y) /\ y # target /\ y \notin step1Merged}
        guardRuns == aliasPath = "guard" /\ M # {}
        syncRuns  == aliasPath = "sync"
        \* AliasGuard (today): invalidate on distinct agents or distinct MACs, else merge
        \* through MergeEngine (whose source-authority guard may still refuse it).
        \* Sync.Aliases (#4609): invalidate when both are identified, else merge.
        invalidate(y) ==
            \/ guardRuns /\ Bug("alias_merge_on_unknown_mac")
                         /\ (DistinctAgents(y, target) \/ DistinctMacs(y, target))
            \/ guardRuns /\ ~Bug("alias_merge_on_unknown_mac") /\ IdsHeld(y) # {}
            \/ syncRuns /\ DistinctIdentifiedIn(owner1, y, target)
        mergeTry(y) ==
            /\ ~invalidate(y)
            /\ \/ guardRuns /\ Bug("alias_merge_on_unknown_mac")
               \/ syncRuns /\ IdsHeldIn(owner1, y) = {}
        mergeOk(y) == mergeTry(y) /\ ~SrcConflictIn(owner1, {y, target}) /\ ~DistinctAgents(y, target)
        step2Inval  == {y \in aliasY : invalidate(y)}
        step2Merged == {y \in aliasY : mergeOk(y)}
        srcRefused  == {y \in aliasY : mergeTry(y) /\ SrcConflictIn(owner1, {y, target})}
        merged == step1Merged \cup step2Merged
        decisions ==
            (IF others # {} /\ ~conflictOk
             THEN {[kind |-> IF SrcConflict(M) THEN "source_block" ELSE "policy_block", recs |-> M]}
             ELSE {})
            \cup {[kind |-> "alias_invalidated", recs |-> {y, target}] : y \in step2Inval}
            \cup {[kind |-> "source_block", recs |-> {y, target}] : y \in srcRefused}
            \cup (IF allM \ M # {}
                  THEN {[kind |-> "source_override", recs |-> (allM \ M) \cup {target}]}
                  ELSE {})
            \cup (IF keepsIp THEN {[kind |-> "ip_conflict", recs |-> {target} \cup holders]} ELSE {})
        recorded == {d \in decisions :
                       d.kind \in {"source_block", "source_override", "ip_conflict"}
                       \/ ~Bug("silent_blocks")}
        into2   == [r \in Recs |-> IF r \in merged THEN target ELSE into[r]]
        owner2  == [i \in Ids |-> IF owner1[i] \in step2Merged THEN target ELSE owner1[i]]
        recIp2  == [r \in Recs |->
                      IF r = target THEN (IF keepsIp THEN recIp[r] ELSE p)
                      ELSE IF r \in holders /\ ~keepsIp THEN NoIp
                      ELSE recIp[r]]
    IN
    /\ created' = [r \in Recs |-> created[r] \/ r = target]
    /\ into' = into2
    /\ owner' = owner2
    /\ recIp' = recIp2
    /\ alias' = [q \in Ips |->
                   LET kept == (alias[q] \ merged) \ (IF q = p THEN step2Inval ELSE {}) IN
                   (IF alias[q] \cap merged # {} THEN kept \cup {target} ELSE kept)
                   \cup (IF recordAlias /\ q = p THEN {target} ELSE {})]
    /\ ifClaims' = [r \in Recs |-> IF r = target
                                   THEN ifClaims[r] \cup claims \cup UNION {ifClaims[m] : m \in merged}
                                   ELSE ifClaims[r]]
    /\ phys' = PhysAfter(h, S, p, merged, target, owner2, into2, recIp2)
    /\ act' = [name |-> kind, ids |-> S, ip |-> p, decisions |-> decisions,
               recorded |-> recorded, addressMerged |-> step2Merged]
    /\ UNCHANGED ipAt

\* Armis sync: the Armis device id, plus the device's MACs when Armis reports them. Its update
\* carries a non-MAC identifier, so Sync.Aliases.process_alias_conflicts/2 runs.
ArmisObserve(h, x) ==
    /\ SrcOf[h] # NoId /\ IfPhys[x] = h /\ ipAt[x] # NoIp
    /\ \E ra \in BOOLEAN :
         Resolve(h, x, {SrcOf[h]} \cup (IF ArmisMacs THEN MacsOf(h) ELSE {}), ra, "sync", "Armis", {})

\* netprobe census: one interface's MAC and address, through SyncIngestor. A census update is an
\* observer source with no non-MAC identifier, so Sync.Aliases never merges on it.
ArpObserve(h, x) ==
    /\ IfPhys[x] = h /\ ipAt[x] # NoIp /\ IfMac[x] # NoId
    /\ \E ra \in BOOLEAN : Resolve(h, x, {IfMac[x]}, ra, "none", "Arp", {})

\* Agent check-in: AgentGatewaySync.ensure_device_for_agent/2 resolves through the Resolver,
\* so AliasGuard runs on the strong-match branch.
AgentObserve(h, x) ==
    /\ AgentOf[h] # NoId /\ IfPhys[x] = h /\ ipAt[x] # NoIp
    /\ \E ra \in BOOLEAN : Resolve(h, x, {AgentOf[h]} \cup MacsOf(h), ra, "guard", "Agent", {})

\* Mapper/SNMP discovery polled at interface x's address, reporting every interface MAC.
\* Today (MapperResultsIngestor.resolve_device_ids/2): the live device holding the address takes
\* the interface table; else a confirmed alias holder of the address does; else DIRE creates or
\* resolves the device. An attach registers the MACs only as interface claims.
\* Goal: the reported MACs resolve the device; the address is evidence only.
MapperAttach(h, x, r) ==
    /\ ifClaims' = [ifClaims EXCEPT ![r] = @ \cup MacsOf(h)]
    /\ act' = [name |-> "Discovery", ids |-> MacsOf(h), ip |-> ipAt[x], decisions |-> {},
               recorded |-> {}, addressMerged |-> {}]
    /\ UNCHANGED <<ipAt, created, into, owner, recIp, alias, phys>>

MapperObserve(h, x) ==
    LET p == ipAt[x]
        holdersAt == {r \in Recs : Live(r) /\ recIp[r] = p}
        aliasAt   == {r \in alias[p] : Live(r)}
    IN
    /\ IfPhys[x] = h /\ p # NoIp /\ MacsOf(h) # {}
    /\ IF Bug("mapper_resolves_by_address") /\ holdersAt # {}
       THEN \E r \in holdersAt : MapperAttach(h, x, r)
       ELSE IF Bug("mapper_resolves_by_address") /\ aliasAt # {}
       THEN \E r \in aliasAt : MapperAttach(h, x, r)
       ELSE \E ra \in BOOLEAN : Resolve(h, x, MacsOf(h), ra, "guard", "Discovery", MacsOf(h))

\* Sweep: an address answered. SweepResultsIngestor attaches it to the live holder or alias
\* holder of the address, and otherwise creates a provisional record seeded from the address
\* (create_available_unknown_devices/5).
SweepObserve(h, x) ==
    /\ IfPhys[x] = h /\ ipAt[x] # NoIp
    /\ Resolve(h, x, {}, FALSE, "none", "Sweep", {})

Next ==
    \/ \E x \in Ifaces, p \in Ips \cup {NoIp} : Lease(x, p)
    \/ \E h \in Phys, x \in Ifaces :
         \/ "Armis" \in Observers /\ ArmisObserve(h, x)
         \/ "Arp" \in Observers /\ ArpObserve(h, x)
         \/ "Agent" \in Observers /\ AgentObserve(h, x)
         \/ "Discovery" \in Observers /\ MapperObserve(h, x)
         \/ "Sweep" \in Observers /\ SweepObserve(h, x)

Spec == Init /\ [][Next]_vars

---------------------------------------------------------------------------
(* Properties -- the goal requirements (update-dire-strong-identity-goal) *)

\* Address Is Evidence, Not Identity; Randomized MACs Are Evidence Only:
\* no live record describes two physical devices.
NoFalseMerge == \A r \in Recs : Live(r) => Cardinality(phys[r]) <= 1

\* Interface Identifiers Belong To Their Device: a MAC in a record's own interface table
\* belongs to a physical device the record describes.
NoFalseInterfaceClaim ==
    \A r \in Recs : Live(r) /\ phys[r] # {} =>
        \A m \in ifClaims[r] : \E h \in phys[r] : m \in MacsOf(h)

\* Source-Authoritative Identifiers Govern Identity.
DistinctSourceIdsNeverMerge == \A r \in Recs : Live(r) => Cardinality(SrcHeld(r)) <= 1

\* Duplicates Converge / Interface Identifiers Belong To Their Device: once an observation
\* reports identifiers together, every live record owning one of them is the same record --
\* unless two of those records hold different source-authoritative identifiers or different
\* agents, which stay separate by design (and that decision is recorded).
OwnersAfter(I) == {CanonIn(into', owner'[i], Cardinality(Recs)) : i \in {j \in I : owner'[j] # NoRec}}
EvidenceConverges ==
    [][Cardinality(OwnersAfter(act'.ids)) <= 1
       \/ SrcConflictIn(owner', OwnersAfter(act'.ids))
       \/ \E a, b \in OwnersAfter(act'.ids) :
            /\ HeldIn(owner', a, AgentIds) # {} /\ HeldIn(owner', b, AgentIds) # {}
            /\ HeldIn(owner', a, AgentIds) \cap HeldIn(owner', b, AgentIds) = {}]_vars

\* Address Is Evidence, Not Identity: no merge is ever caused by address or IP-alias evidence.
AddressNeverMerges == [][act'.addressMerged = {}]_vars

\* An address follows the device observed at it: after an identity-bearing observation lands,
\* the record it landed on holds the observed address.
ObservedAddressHeld ==
    [][(act'.name \in {"Armis", "Arp", "Agent"} /\ act'.ids # {}) =>
         \E r \in Recs : created'[r] /\ into'[r] = NoRec /\ recIp'[r] = act'.ip
                         /\ act'.ids \cap HeldIn(owner', r, Ids) # {}]_vars

\* Identity Decisions Are Never Silent.
NoSilentDecision == [][act'.decisions \subseteq act'.recorded]_vars

=============================================================================
