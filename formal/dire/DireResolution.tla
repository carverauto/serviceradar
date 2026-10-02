--------------------------- MODULE DireResolution ---------------------------
(***************************************************************************)
(* DIRE identity resolution against physical ground truth.                  *)
(* See openspec/specs/device-identity-reconciliation (the requirements)     *)
(* and openspec/specs/dire-formal-model (the verification).                 *)
(*                                                                          *)
(* The world: physical devices own interfaces; an interface has a true MAC  *)
(* (hardware or randomized) and leases an address, and DHCP moves addresses *)
(* between interfaces. Observers report what they would really see, and     *)
(* each observer follows the real ingestion path it models:                 *)
(*   Armis   -> SyncIngestor (BatchResolver, DeviceWrites, Sync.Aliases)    *)
(*   Arp     -> netprobe census -> SyncIngestor (no alias merge)            *)
(*   Agent   -> AgentGatewaySync -> Resolver (AliasGuard)                   *)
(*   Mapper  -> MapperResultsIngestor (its interface MACs, through DIRE)    *)
(*   Sweep   -> SweepResultsIngestor (attach, or a provisional seed)        *)
(* A ghost variable, phys, tracks which physical devices' identity-bearing  *)
(* observations went into each record, so "one record describes two        *)
(* devices" is checkable. The shape of every action was checked against    *)
(* traces recorded from the real code (formal/dire/traces).                 *)
(*                                                                          *)
(* A source can re-identify a device (Rekey): the source id is a variable, *)
(* and every environment without the Rekeys constant keeps it constant.    *)
(* The source's exact collections (Collect) age the ids it stops reporting *)
(* on a coarse absence clock, and a stale id retires into the archive      *)
(* (RetireAbsent), which ingest still consults.                            *)
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
    SrcOf0,        \* [Phys -> SrcIds \cup {NoId}]: the Armis device id at Init, if Armis knows it
    Rekeys,        \* whether the source may re-identify a device under another id (Rekey)
    FreshIds,      \* whether a re-key always uses an id the source never issued before
    AgentOf,       \* [Phys -> AgentIds \cup {NoId}]: the agent running on the device, if any
    ArmisMacs,     \* whether Armis reports the device's MACs with its id
    AgentIds,      \* agent ids (agent_id identifiers)
    SrcIds,        \* source-authoritative identifiers (one source)
    HwIds,         \* globally-unique MACs
    LaaIds,        \* locally-administered (randomized) MACs
    Ips,
    Observers,     \* which observers exist in this environment
    Spare,         \* record names a write may use for a record no identifier is named for
    NoId, NoIp, NoRec,
    Bugs,
    Unsafe         \* design alternatives rejected for identity safety (negative configurations)

KnownBugs == {"retired_source_id_vetoes", "stale_holder_keeps_address", "released_seed_stays_live"}
ASSUME Bugs \subseteq KnownBugs

Bug(b) == b \in Bugs

UnsafeAlternatives == {"retired_ids_forgotten"}
ASSUME Unsafe \subseteq UnsafeAlternatives

MacIds == HwIds \cup LaaIds
Ids    == AgentIds \cup SrcIds \cup MacIds
\* A record is named by the seed its uid was derived from: the highest-priority identifier
\* (Ids.generate_deterministic_device_id/1) or, for an identifier-less update, the address.
Recs   == Ids \cup Ips \cup Spare

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
    act,      \* the last step: observer, reported ids, address, decisions, address merges
    srcOf,    \* the source id the source currently reports for each device
    absence,  \* per source id: Unissued, Present in the last collection, or absent (Fresh, Stale)
    archive,  \* device_identifier_archive: source id -> the records it was retired from
    recFs,    \* ghost: the devices whose source first-seen time and hostname a record carries
    addrFresh \* last_seen_time is newer than identity_observed_at: a sighting that is not
              \* identity-bearing (a sweep, a census, an address-only poll) touched it last

vars == <<ipAt, created, into, owner, recIp, alias, phys, ifClaims, act, srcOf, absence, archive,
          recFs, addrFresh>>

\* The coarse absence clock: Fresh is absent from fewer than N exact collections or for less than
\* T; Stale is absent from N consecutive exact collections and for at least T.
Absences == {"Unissued", "Present", "Fresh", "Stale"}

DecisionKinds == {"policy_block", "source_block", "alias_invalidated", "source_override",
                  "ip_conflict", "source_id_retired"}
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
    /\ srcOf \in [Phys -> SrcIds \cup {NoId}]
    /\ absence \in [SrcIds -> Absences]
    /\ archive \in [SrcIds -> SUBSET Recs]
    /\ recFs \in [Recs -> SUBSET Phys]
    /\ addrFresh \in [Recs -> BOOLEAN]

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

\* The source ids a record held and that were retired from it, or from a record merged into it,
\* on archive ar and merge redirects i.
ArchivedIn(ar, i, r) == {a \in SrcIds : \E q \in ar[a] : CanonIn(i, q, Cardinality(Recs)) = r}
ArchivedOf(r) == ArchivedIn(archive, into, r)
\* The source ids a record holds or held (D2: SourceAuthorityGuard reads both tables).
SrcHistIn(o, ar, i, r) == SrcHeldIn(o, r) \cup ArchivedIn(ar, i, r)
SrcHist(r) == SrcHistIn(owner, archive, into, r)

\* SourceAuthorityGuard.conflict_from_rows/2: two records holding or having held disjoint,
\* non-empty sets of the same source's identifiers. Recorded (record_blocked/3).
SrcConflictIn(o, ar, i, M) ==
    \E a, b \in M : /\ a # b /\ SrcHistIn(o, ar, i, a) # {} /\ SrcHistIn(o, ar, i, b) # {}
                   /\ SrcHistIn(o, ar, i, a) \cap SrcHistIn(o, ar, i, b) = {}
SrcConflict(M) == SrcConflictIn(owner, archive, into, M)

\* The ids the source reported in its last collection, and reports now.
CurrentIds == {srcOf[h] : h \in Phys} \ {NoId}

\* AliasGuard.distinct_agent_identity_conflict?/3; MergeEngine refuses every automatic merge of
\* such a pair (merge_guard_violation/4).
DistinctAgents(a, b) == AgentHeld(a) # {} /\ AgentHeld(b) # {} /\ AgentHeld(a) \cap AgentHeld(b) = {}

\* AliasGuard.same_chassis?/5: one record's own interface table claims a MAC the other holds.
SameChassis(a, b) == ifClaims[a] \cap MacsHeld(b) # {} \/ ifClaims[b] \cap MacsHeld(a) # {}

\* AliasGuard.distinct_identified_devices?/3 (#4609), on post-registration ownership o.
DistinctIdentifiedIn(o, a, b) == IdsHeldIn(o, a) # {} /\ IdsHeldIn(o, b) # {} /\ ~SameChassis(a, b)

\* MergePolicy.merge_allowed_for_matches?/1 over the identifiers that matched: any set containing
\* an agent, source-authoritative or globally-unique identifier (#4612); never an all-randomized
\* set.
PolicyAllows(matched) == matched \cap (AgentIds \cup SrcIds \cup HwIds) # {}

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
    /\ srcOf = SrcOf0
    /\ absence = [a \in SrcIds |-> IF \E h \in Phys : SrcOf0[h] = a THEN "Present" ELSE "Unissued"]
    /\ archive = [a \in SrcIds |-> {}]
    /\ recFs = [r \in Recs |-> {}]
    /\ addrFresh = [r \in Recs |-> FALSE]

\* DHCP: an interface leases a free address or releases its lease.
Lease(x, p) ==
    /\ p # ipAt[x]
    /\ p = NoIp \/ ~\E y \in Ifaces : ipAt[y] = p
    /\ ipAt' = [ipAt EXCEPT ![x] = p]
    /\ act' = [name |-> "Lease", ids |-> {}, ip |-> NoIp, decisions |-> {}, recorded |-> {},
               addressMerged |-> {}]
    /\ UNCHANGED <<created, into, owner, recIp, alias, phys, ifClaims, srcOf, absence, archive,
                   recFs, addrFresh>>

\* The phys ghost after a step: merged records' devices join the record they were merged into
\* (m1 into t1, m2 into t2), and an identity-bearing observation joins the record it landed on --
\* the one now owning its identifiers, or, when they are split across records, the live record
\* holding the observed address. The written record is t2.
PhysAfter(h, S, p, m1, t1, m2, t2, owner2, into2, recIp2) ==
    LET canon2(r) == CanonIn(into2, r, Cardinality(Recs))
        cands == {canon2(owner2[i]) : i \in {j \in S : owner2[j] # NoRec}}
        holders == {r \in Recs : (created[r] \/ r = t2) /\ into2[r] = NoRec /\ recIp2[r] = p}
        landing == IF Cardinality(cands) = 1 THEN CHOOSE r \in cands : TRUE
                   ELSE IF cands # {} /\ holders # {} THEN CHOOSE r \in holders : TRUE
                   ELSE NoRec
        base == [r \in Recs |-> phys[r]
                                \cup (IF r = t1 THEN UNION {phys[m] : m \in m1} ELSE {})
                                \cup (IF r = t2 THEN UNION {phys[m] : m \in m2} ELSE {})]
    IN [r \in Recs |-> IF S # {} /\ r = landing THEN base[r] \cup {h} ELSE base[r]]

\* One observation of physical device h at interface x's address, carrying identifiers S,
\* through the resolver and the device write.
\*   aliasPath: "none" (census), "sync" (Sync.Aliases), "guard" (AliasGuard, Resolver path)
\*   recordAlias: this update's address is recorded as a (confirmed) alias of the result
\*   claims: interface MACs the observation registers as the result's own interface table
\*   keepIps: addresses an existing result keeps instead of moving to this one (the mapper's
\*            device reports all of its own addresses; other observers pass {})
Resolve(h, x, S, recordAlias, aliasPath, kind, claims, keepIps) ==
    LET p       == ipAt[x]
        \* The identifiers the uid is derived from and that make DeviceWrites take the
        \* strong-identity branch at the address: exactly the ones the observation looks up and
        \* registers. A randomized MAC is never one (Ids.has_strong_identifier?/1, #4760).
        strong  == S
        srcS    == S \cap SrcIds
        \* A matched record holding, or having held, a different source-authoritative identifier
        \* than the one this update carries is not a match: the source-authoritative identifier
        \* decides, and the override is recorded (SourceAuthorityGuard.source_mismatch?/3, applied
        \* by BatchResolver.strong_match/2 and Resolver.lookup_governed_matches/3; #4611). A
        \* retired id keeps this veto (D2), so a MAC never attaches a new id to an old record.
        srcMismatch(r) == srcS # {} /\ SrcHist(r) # {} /\ SrcHeld(r) \cap srcS = {}
        allM    == {Canon(owner[i]) : i \in {j \in S : owner[j] # NoRec}}
        M       == {r \in allM : ~srcMismatch(r)}
        matched == {i \in S : owner[i] # NoRec /\ Canon(owner[i]) \in M}
    IN
    \E X \in (IF M # {} THEN M ELSE {NoRec}),
       stale \in (IF Bug("stale_holder_keeps_address") /\ kind = "Armis" THEN BOOLEAN ELSE {FALSE}) :
    LET \* --- Step 1: strong-identifier conflict (merge_conflicting_devices/4) ---
        others     == M \ {X}
        conflictOk == others # {} /\ ~SrcConflict(M) /\ PolicyAllows(matched)
        step1Merged == IF conflictOk THEN {o \in others : ~DistinctAgents(o, X)} ELSE {}
        \* --- Fallback when nothing matched (resolve_fallback_device_id/3) ---
        holderAt == {r \in Recs : Live(r) /\ r \notin step1Merged /\ recIp[r] = p}
        target0 ==
            IF M # {} THEN X
            ELSE IF strong # {} THEN Canon(Seed(strong))
            ELSE LET weak == holderAt \cup {r \in alias[p] : Live(r)}
                 IN IF weak # {} THEN CHOOSE r \in weak : TRUE ELSE Canon(p)
        \* --- The device write and ocsf_devices_unique_active_ip_idx
        \*     (DeviceWrites.resolve_record_active_ip/7; for an existing device the mapper
        \*     polled, MapperResultsIngestor.move_device_address/4) ---
        others0   == holderAt \ {target0}
        seedHold  == {r \in others0 : IdsHeld(r) = {}}
        \* A strong write creating a new record onto an address held by an anchorless provisional
        \* seed adopts the seed. An existing record never does (#4705): it takes the address below
        \* and the seed releases it.
        adopt     == strong # {} /\ ~created[target0] /\ seedHold # {}
        target    == IF adopt THEN CHOOSE r \in seedHold : TRUE ELSE target0
        \* An existing result whose address is still one of its own keeps it, and this write
        \* claims no address at all.
        keepAddr  == created[target] /\ recIp[target] \in keepIps
        \* An identity-bearing write at an address another live record holds: the address follows
        \* the device observed at it, so the holder releases it (its address is cleared) and the
        \* decision is recorded (DeviceWrites.claim_address_from_holder/4; #4639). The rule
        \* releases only for an observation newer than the holder's. The model has no clock: the
        \* incoming observation is the newest identity-bearing one, and D7 compares it with the
        \* holder's identity_observed_at, which only identity-bearing observations advance.
        \*   Bug stale_holder_keeps_address: an Armis sync compares Armis's own last-seen time
        \*       for the device with the holder's last_seen_time, which a sweep or a census
        \*       refreshes (observed_after?/2), so a holder one of them touched last may keep
        \*       the address. The write then claims no address and the holder keeps it. An agent
        \*       check-in or a mapper poll compares the current time, and always wins.
        rivals    == IF keepAddr THEN {} ELSE holderAt \ {target}
        staleHeld == IF stale THEN {r \in rivals : addrFresh[r]} ELSE {}
        holders   == rivals \ staleHeld
        ipConflict == strong # {} /\ rivals # {}
        \* D8: an anchorless provisional seed (no identifier, current or retired) that releases its
        \* only address to an identified device is soft-deleted in the same transaction, reason
        \* seed_released; the model writes that as the record no longer existing, so a later
        \* sweep of the address with no holder brings it back as a new seed. In every environment
        \* with a strong writer an anchorless record is a sweep seed: an address-only Arp or
        \* Discovery record needs a device with no globally-unique MAC (the phones environment,
        \* which has no strong writer).
        \*   Bug released_seed_stays_live: the seed releases the address and stays live, an
        \*       addressless shell with nothing that ever removes it but ephemeral expiry.
        released  == IF strong # {} /\ ~Bug("released_seed_stays_live")
                     THEN {r \in holders : IdsHeld(r) = {} /\ ArchivedOf(r) = {}}
                     ELSE {}
        owner1 == [i \in Ids |->
                     IF owner[i] \in step1Merged THEN target0
                     ELSE IF i \in S /\ owner[i] = NoRec THEN target
                     ELSE owner[i]]
        \* --- Step 2: the IP-alias merge ---
        \* Goal: address or alias evidence never merges two records; an identified holder of the
        \* alias has the alias invalidated and an address-only holder is left alone.
        aliasY == {y \in alias[p] : Live(y) /\ y # target /\ y \notin step1Merged}
        guardRuns == aliasPath = "guard" /\ M # {}
        syncRuns  == aliasPath = "sync"
        \* AliasGuard (#4610): never merges; an identified holder has the alias invalidated and an
        \* address-only holder is left alone.
        \* Sync.Aliases (#4609): invalidate when both are identified, else merge.
        invalidate(y) ==
            \/ guardRuns /\ IdsHeld(y) # {}
            \/ syncRuns /\ DistinctIdentifiedIn(owner1, y, target)
        mergeTry(y) ==
            /\ ~invalidate(y)
            /\ syncRuns /\ IdsHeldIn(owner1, y) = {}
        srcConflict2(y) == SrcConflictIn(owner1, archive, into, {y, target})
        mergeOk(y) == mergeTry(y) /\ ~srcConflict2(y) /\ ~DistinctAgents(y, target)
        step2Inval  == {y \in aliasY : invalidate(y)}
        step2Merged == {y \in aliasY : mergeOk(y)}
        srcRefused  == {y \in aliasY : mergeTry(y) /\ srcConflict2(y)}
        merged == step1Merged \cup step2Merged
        decisions ==
            (IF others # {} /\ ~conflictOk
             THEN {[kind |-> IF SrcConflict(M) THEN "source_block" ELSE "policy_block", recs |-> M]}
             ELSE {})
            \cup {[kind |-> "alias_invalidated", recs |-> {y, target}] : y \in step2Inval}
            \cup {[kind |-> "source_block", recs |-> {y, target}] : y \in srcRefused}
            \cup (IF allM \ M # {}
                  THEN {[kind |-> "source_override", recs |-> (allM \ M) \cup {target0}]}
                  ELSE {})
            \cup (IF ipConflict THEN {[kind |-> "ip_conflict", recs |-> {target} \cup rivals]} ELSE {})
        \* Every decision leaves a persisted identity decision (DecisionLog.record/4, #4613).
        recorded == decisions
        into2   == [r \in Recs |-> IF r \in step1Merged THEN target0
                               ELSE IF r \in step2Merged THEN target
                               ELSE into[r]]
        owner2  == [i \in Ids |-> IF owner1[i] \in step2Merged THEN target ELSE owner1[i]]
        recIp2  == [r \in Recs |->
                      IF r = target THEN (IF keepAddr \/ staleHeld # {} THEN recIp[r] ELSE p)
                      ELSE IF r \in holders THEN NoIp
                      ELSE recIp[r]]
    IN
    /\ created' = [r \in Recs |-> (created[r] \/ r = target) /\ r \notin released]
    /\ into' = into2
    /\ owner' = owner2
    /\ recIp' = recIp2
    /\ alias' = [q \in Ips |->
                   LET kept == (alias[q] \ merged) \ (IF q = p THEN step2Inval ELSE {}) IN
                   kept \cup (IF alias[q] \cap step1Merged # {} THEN {target0} ELSE {})
                        \cup (IF alias[q] \cap step2Merged # {} THEN {target} ELSE {})
                   \cup (IF recordAlias /\ q = p THEN {target} ELSE {})]
    /\ ifClaims' = [r \in Recs |->
                      ifClaims[r]
                      \cup (IF r = target0 THEN UNION {ifClaims[m] : m \in step1Merged} ELSE {})
                      \cup (IF r = target
                            THEN claims \cup UNION {ifClaims[m] : m \in step2Merged}
                            ELSE {})]
    /\ phys' = PhysAfter(h, S, p, step1Merged, target0, step2Merged, target, owner2, into2, recIp2)
    /\ act' = [name |-> kind, ids |-> S, ip |-> p, decisions |-> decisions,
               recorded |-> recorded, addressMerged |-> step2Merged]
    \* A source sync writes the device's first-seen time and hostname to the record it lands on;
    \* a merge keeps both records' values.
    /\ recFs' = [r \in Recs |->
                   recFs[r]
                   \cup (IF kind = "Armis" /\ r = target THEN {h} ELSE {})
                   \cup (IF r = target0 THEN UNION {recFs[m] : m \in step1Merged} ELSE {})
                   \cup (IF r = target THEN UNION {recFs[m] : m \in step2Merged} ELSE {})]
    \* The write advances the record's last_seen_time, and its identity_observed_at only when it
    \* is the device's own identity-bearing report (D7): never a census or an address-only poll.
    /\ addrFresh' = [r \in Recs |-> IF r = target THEN kind = "Arp" \/ S = {} ELSE addrFresh[r]]
    /\ UNCHANGED <<ipAt, srcOf, absence, archive>>

\* Armis sync: the Armis device id, plus the device's MACs when Armis reports them. Its update
\* carries a non-MAC identifier, so Sync.Aliases.process_alias_conflicts/2 runs.
ArmisObserve(h, x) ==
    /\ srcOf[h] # NoId /\ IfPhys[x] = h /\ ipAt[x] # NoIp
    /\ \E ra \in BOOLEAN :
         Resolve(h, x, {srcOf[h]} \cup (IF ArmisMacs THEN MacsOf(h) ELSE {}), ra, "sync",
                 "Armis", {}, {})

\* netprobe census: one interface's MAC and address, through SyncIngestor. A census update is an
\* observer source with no non-MAC identifier, so Sync.Aliases never merges on it. A randomized
\* MAC from a census is neither looked up nor registered
\* (SourcePolicy.include_mac_identifier?/1, census_anchorable_mac?/1), nor does the record's uid
\* derive from it (Ids.has_strong_identifier?/1, #4760): that sighting is address-only.
ArpObserve(h, x) ==
    /\ IfPhys[x] = h /\ ipAt[x] # NoIp /\ IfMac[x] # NoId
    /\ \E ra \in BOOLEAN : Resolve(h, x, {IfMac[x]} \cap HwIds, ra, "none", "Arp", {}, {})

\* Agent check-in: AgentGatewaySync.ensure_device_for_agent/2 resolves through the Resolver,
\* so AliasGuard runs on the strong-match branch.
AgentObserve(h, x) ==
    /\ AgentOf[h] # NoId /\ IfPhys[x] = h /\ ipAt[x] # NoIp
    /\ \E ra \in BOOLEAN : Resolve(h, x, {AgentOf[h]} \cup MacsOf(h), ra, "guard", "Agent", {}, {})

\* Mapper/SNMP discovery polled at interface x's address, reporting every interface MAC and
\* address (MapperResultsIngestor.resolve_device_ids/2). The reported globally-unique MACs
\* resolve the device through the Resolver, which runs AliasGuard at the polled address, and
\* they become the result's interface claims; the address is evidence only. A new device is
\* written at the polled address; an existing one keeps an address it still reports. A
\* randomized MAC never identifies a device: a poll reporting no globally-unique MAC has only
\* the address to go on, like a sweep, and claims no interface.
OwnIps(h) == {ipAt[y] : y \in {z \in Ifaces : IfPhys[z] = h}} \ {NoIp}

MapperObserve(h, x) ==
    LET ids == MacsOf(h) \cap HwIds IN
    /\ IfPhys[x] = h /\ ipAt[x] # NoIp /\ MacsOf(h) # {}
    /\ IF ids # {}
       THEN \E ra \in BOOLEAN : Resolve(h, x, ids, ra, "guard", "Discovery", ids, OwnIps(h))
       ELSE Resolve(h, x, {}, FALSE, "none", "Discovery", {}, {})

\* Sweep: an address answered (SweepResultsIngestor.process_batch/4). The lookup prefers a
\* confirmed alias holder of the address, then the record holding it
\* (DeviceLookup.batch_lookup_by_ip/2), and the sighting refreshes that record's last_seen_time
\* and availability and nothing else: a sweep never writes or moves an address and never merges.
\* An address nothing holds gets a provisional record seeded from it
\* (create_available_unknown_devices/5); its uid derives from the address, so a record already
\* named by the address that holds it no longer -- merged away, or a shell that released it --
\* makes the create a duplicate, which is skipped.
SweepObserve(h, x) ==
    LET p        == ipAt[x]
        aliasAt  == {r \in alias[p] : Live(r)}
        holderAt == {r \in Recs : Live(r) /\ recIp[r] = p}
        seen     == IF aliasAt # {} THEN aliasAt ELSE holderAt
    IN
    /\ IfPhys[x] = h /\ p # NoIp
    /\ \/ \E r \in seen :
            /\ addrFresh' = [addrFresh EXCEPT ![r] = TRUE]
            /\ UNCHANGED <<created, recIp>>
       \/ /\ seen = {} /\ ~created[p]
          /\ created' = [created EXCEPT ![p] = TRUE]
          /\ recIp' = [recIp EXCEPT ![p] = p]
          /\ addrFresh' = [addrFresh EXCEPT ![p] = TRUE]
    /\ act' = [name |-> "Sweep", ids |-> {}, ip |-> p, decisions |-> {}, recorded |-> {},
               addressMerged |-> {}]
    /\ UNCHANGED <<ipAt, into, owner, alias, phys, ifClaims, srcOf, absence, archive, recFs>>

\* The source re-identifies device h: it reports h under id a from now on (a source-side merge or
\* re-identification), joins the source (from NoId) or leaves it (to NoId). No other device is
\* reported with a. Under FreshIds the source never issued a before; otherwise it may also
\* re-issue an id DIRE has retired. (An id re-issued while DIRE still holds it as current is
\* indistinguishable from the same asset, and is outside the model.)
Rekey(h, a) ==
    /\ Rekeys
    /\ a # srcOf[h]
    /\ a # NoId => /\ \A k \in Phys : srcOf[k] # a
                   /\ \/ absence[a] = "Unissued"
                      \/ ~FreshIds /\ absence[a] = "Stale" /\ owner[a] = NoRec
    /\ srcOf' = [srcOf EXCEPT ![h] = a]
    /\ absence' = IF a = NoId THEN absence ELSE [absence EXCEPT ![a] = "Present"]
    /\ act' = [name |-> "Rekey", ids |-> {}, ip |-> NoIp, decisions |-> {}, recorded |-> {},
               addressMerged |-> {}]
    /\ UNCHANGED <<ipAt, created, into, owner, recIp, alias, phys, ifClaims, archive, recFs,
                   addrFresh>>

\* An exact collection of the source activates (ArmisSourceSnapshot.activate/3). Every id it
\* reports is Present. An id it does not report ages: absent once it is Fresh, and it turns Stale
\* after N consecutive exact collections and T, which this coarse clock reaches on any later
\* collection. One absence never retires an id.
Collect ==
    /\ Rekeys
    /\ \E aged \in [SrcIds -> {"Fresh", "Stale"}] :
         absence' = [a \in SrcIds |->
                       IF a \in CurrentIds THEN "Present"
                       ELSE CASE absence[a] = "Present" -> "Fresh"
                              [] absence[a] = "Fresh" -> aged[a]
                              [] OTHER -> absence[a]]
    /\ act' = [name |-> "Collect", ids |-> {}, ip |-> NoIp, decisions |-> {}, recorded |-> {},
               addressMerged |-> {}]
    /\ UNCHANGED <<ipAt, created, into, owner, recIp, alias, phys, ifClaims, srcOf, archive, recFs,
                   addrFresh>>

\* The retirement job an activation enqueues (D1): a stale id leaves device_identifiers for the
\* archive, remembering the record that held it, and the decision is recorded.
\*   Bug retired_source_id_vetoes: nothing retires an id the source stopped reporting, so the
\*       old record keeps it, and with it the veto against the device's new id, for ever.
\*   Unsafe retired_ids_forgotten: retirement drops the identifier without archiving it, so
\*       nothing remembers that the record held it.
RetireAbsent(a) ==
    /\ ~Bug("retired_source_id_vetoes")
    /\ absence[a] = "Stale" /\ owner[a] # NoRec
    /\ owner' = [owner EXCEPT ![a] = NoRec]
    /\ archive' = IF "retired_ids_forgotten" \in Unsafe THEN archive
                  ELSE [archive EXCEPT ![a] = @ \cup {owner[a]}]
    /\ LET d == {[kind |-> "source_id_retired", recs |-> {owner[a]}]} IN
       act' = [name |-> "Retire", ids |-> {}, ip |-> NoIp, decisions |-> d, recorded |-> d,
               addressMerged |-> {}]
    /\ UNCHANGED <<ipAt, created, into, recIp, alias, phys, ifClaims, srcOf, absence, recFs,
                   addrFresh>>

Next ==
    \/ \E x \in Ifaces, p \in Ips \cup {NoIp} : Lease(x, p)
    \/ \E h \in Phys, a \in SrcIds \cup {NoId} : Rekey(h, a)
    \/ Collect
    \/ \E a \in SrcIds : RetireAbsent(a)
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
       \/ SrcConflictIn(owner', archive', into', OwnersAfter(act'.ids))
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

\* Randomized MACs Are Evidence Only: no record is identified by a randomized MAC. A record is
\* named by the identifier its uid was derived from, so a record named by one is identified by it.
RandomizedMacsNeverIdentify == \A m \in LaaIds : ~created[m]

\* Identity Decisions Are Never Silent.
NoSilentDecision == [][act'.decisions \subseteq act'.recorded]_vars

---------------------------------------------------------------------------
(* Properties -- source identifier change (add-source-id-succession) *)

\* Source ids a record still holds that the source no longer reports.
AbsentHeld == {a \in SrcIds : owner[a] # NoRec /\ a \notin CurrentIds}
\* A retirement the next job would still make.
PendingRetirement == ~Bug("retired_source_id_vetoes") /\ AbsentHeld # {}
\* At rest: every id the source stopped reporting has been absent long enough to retire, and
\* neither the retirement job nor the reconciler would change anything.
AtRest ==
    /\ \A a \in AbsentHeld : absence[a] = "Stale"
    /\ ~PendingRetirement

\* Source Identifiers Retire When Their Source Stops Reporting Them: at rest, at most one live
\* record holding a source id describes each physical device.
OneSourceRecordPerDevice ==
    AtRest => \A h \in Phys :
                Cardinality({r \in Recs : Live(r) /\ h \in phys[r] /\ SrcHeld(r) # {}}) <= 1

\* A device's current source id, once owned, is owned by the record describing the device.
CurrentSourceIdResolves ==
    \A h \in Phys : srcOf[h] # NoId /\ owner[srcOf[h]] # NoRec =>
                     h \in phys[Canon(owner[srcOf[h]])]

\* Source-Authoritative Identifiers Govern Identity, over current ids: no merge joins two records
\* holding distinct current source ids.
NoMergeOfCurrentSourceIds ==
    [][\A r \in Recs :
         into[r] = NoRec /\ into'[r] # NoRec =>
           LET cr == SrcHeld(r) \cap CurrentIds
               ct == SrcHeld(CanonIn(into', r, Cardinality(Recs))) \cap CurrentIds
           IN cr = {} \/ ct = {} \/ cr \cap ct # {}]_vars

\* No live record holds neither an identifier nor an address. A record holding only retired ids is
\* marked source_retired by its retirement and deleted after the grace period (D5, modeled in
\* DireLifecycle), so it is not a shell here.
NoAddresslessShell ==
    \A r \in Recs : Live(r) /\ ArchivedOf(r) = {} => IdsHeld(r) # {} \/ recIp[r] # NoIp

=============================================================================
