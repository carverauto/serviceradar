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
    HostOf,        \* [Phys -> hostnames]: the hostname Armis reports for the device; cloned
                   \* machines share one
    NewFirstSeenIds, \* source ids Armis reports with a new first-seen time; under any other id it
                     \* reports the device's original one
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

KnownBugs == {}
ASSUME Bugs \subseteq KnownBugs

Bug(b) == b \in Bugs

UnsafeAlternatives == {"mac_only_succession", "retired_ids_forgotten",
                       "overlapping_hostname_corroborates"}
ASSUME Unsafe \subseteq UnsafeAlternatives
ASSUME NewFirstSeenIds \subseteq SrcIds

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
    recFs,    \* ghost: the source first-seen times a record carries (FsOf), each naming the
              \* device whose hostname and MACs come with it
    idSeen,   \* identity_observed_at is set: an identity-bearing observation wrote the record (a
              \* source sync, an agent check-in, a poll that identified the device); a sweep, a
              \* census and an address-only poll never do (D7)
    seenWith  \* ghost: the source ids first seen no later than the source last saw the record's
              \* device, that is, already issued at its last source sighting

vars == <<ipAt, created, into, owner, recIp, alias, phys, ifClaims, act, srcOf, absence,
          archive, recFs, idSeen, seenWith>>

\* The coarse absence clock: Fresh is absent from fewer than N exact collections or for less than
\* T; Stale is absent from N consecutive exact collections and for at least T.
Absences == {"Unissued", "Present", "Fresh", "Stale"}

DecisionKinds == {"policy_block", "source_block", "alias_invalidated", "source_override",
                  "ip_conflict", "source_id_retired", "source_id_reactivated", "source_id_reissued",
                  "succession_review"}
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
    /\ recFs \in [Recs -> SUBSET (Phys \X (SrcIds \cup {NoId}))]
    /\ idSeen \in [Recs -> BOOLEAN]
    /\ seenWith \in [Recs -> SUBSET SrcIds]

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

\* SourceAuthorityGuard.conflict_from_rows/2: two records each holding or having held identifiers
\* of the same source. Recorded (record_blocked/3). A value has one holder at a time, so two
\* records' current values are always the disjoint sets the guard tests for; a value the archive
\* keeps for one record and another record holds now was re-issued (D6), and never joins them
\* either.
SrcConflictIn(o, ar, i, M) ==
    \E a, b \in M : /\ a # b /\ SrcHistIn(o, ar, i, a) # {} /\ SrcHistIn(o, ar, i, b) # {}
SrcConflict(M) == SrcConflictIn(owner, archive, into, M)

\* The ids the source reported in its last collection, and reports now.
CurrentIds == {srcOf[h] : h \in Phys} \ {NoId}
\* The ids the source has issued: first seen by now.
Issued == {a \in SrcIds : absence[a] # "Unissued"}

\* AliasGuard.distinct_agent_identity_conflict?/3; MergeEngine refuses every automatic merge of
\* such a pair (merge_guard_violation/4).
DistinctAgents(a, b) == AgentHeld(a) # {} /\ AgentHeld(b) # {} /\ AgentHeld(a) \cap AgentHeld(b) = {}

\* AliasGuard.same_chassis?/5: each record's own interface table claims a MAC the other
\* holds. Reciprocal evidence is required because either reporting device can supply an
\* untrusted one-sided claim. The code additionally scopes each side's claims to the
\* device's own partition; the model abstracts partitions (single-partition assumption),
\* so only the reciprocal shape is expressed here.
SameChassis(a, b) == ifClaims[a] \cap MacsHeld(b) # {} /\ ifClaims[b] \cap MacsHeld(a) # {}

\* AliasGuard.distinct_identified_devices?/3 (#4609), on post-registration ownership o.
DistinctIdentifiedIn(o, a, b) == IdsHeldIn(o, a) # {} /\ IdsHeldIn(o, b) # {} /\ ~SameChassis(a, b)

\* MergePolicy.merge_allowed_for_matches?/1 over the identifiers that matched: any set containing
\* an agent, source-authoritative or globally-unique identifier (#4612); never an all-randomized
\* set.
PolicyAllows(matched) == matched \cap (AgentIds \cup SrcIds \cup HwIds) # {}

\* The globally-unique MACs a record reports (D3): its identifier rows, its own interface table,
\* and the source's observations of the devices it describes, which carry their MACs when the
\* source reports MACs. The archived observation of a retired id is the record's.
SrcMacs(r) == IF ArmisMacs THEN UNION {MacsOf(v[1]) : v \in recFs[r]} ELSE {}
MacEv(r) == (MacsHeld(r) \cup ifClaims[r] \cup SrcMacs(r)) \cap HwIds

\* The first-seen time the source reports for device h under id a: the device's original one, or a
\* new one for an id in NewFirstSeenIds. Two devices never share one.
FsOf(h, a) == <<h, IF a \in NewFirstSeenIds THEN a ELSE NoId>>
HostsOf(fs) == {HostOf[v[1]] : v \in fs}

\* D3 corroboration of record r by the source's observations with first-seen times fs, under ids.
\* The first-seen times agree; the ghost makes that exact (README, "What the models do not
\* express"). Or the hostnames agree, and none of ids was first seen before the source last saw
\* r's device: cloned machines share a hostname while both are in the source, but a re-keyed
\* device appears under its new id only after its old one was last seen.
\*   Unsafe overlapping_hostname_corroborates: a shared hostname corroborates on its own.
CorroboratedBy(r, fs, ids) ==
    \/ recFs[r] \cap fs # {}
    \/ /\ HostsOf(recFs[r]) \cap HostsOf(fs) # {}
       /\ "overlapping_hostname_corroborates" \in Unsafe \/ ids \cap seenWith[r] = {}

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
    /\ idSeen = [r \in Recs |-> FALSE]
    /\ seenWith = [r \in Recs |-> {}]

\* DHCP: an interface leases a free address or releases its lease.
Lease(x, p) ==
    /\ p # ipAt[x]
    /\ p = NoIp \/ ~\E y \in Ifaces : ipAt[y] = p
    /\ ipAt' = [ipAt EXCEPT ![x] = p]
    /\ act' = [name |-> "Lease", ids |-> {}, ip |-> NoIp, decisions |-> {}, recorded |-> {},
               addressMerged |-> {}]
    /\ UNCHANGED <<created, into, owner, recIp, alias, phys, ifClaims, srcOf, absence,
                   archive, recFs, idSeen, seenWith>>

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
        \* D6: a retired id presented again. Resolution consults the archive: the id returns to the
        \* record it was retired from, or that record's merge survivor, when exactly one such
        \* record holds no current (unretired) id of the source, the update agrees with its archived
        \* observation on a globally-unique MAC, and their first-seen times or hostnames agree
        \* (CorroboratedBy). That is a reactivation; the archive row moves back. Otherwise the id is
        \* re-issued: the update never joins the old record, and a record already named by the
        \* id's uid, live or merged away, makes it a new record. (A record holding an archived id
        \* is never deleted here; the grace delete and its restore are in DireLifecycle.)
        retiredS == {a \in srcS : owner[a] = NoRec /\ archive[a] # {}}
        heldBy  == UNION {{Canon(q) : q \in archive[a]} : a \in retiredS}
        revivable == {c \in heldBy : /\ SrcHeld(c) = {} /\ S \cap MacEv(c) # {}
                                     /\ CorroboratedBy(c, {FsOf(h, a) : a \in srcS}, retiredS)}
        reactivated == IF Cardinality(revivable) = 1 THEN revivable ELSE {}
        reissued == retiredS # {} /\ reactivated = {}
        \* A matched record holding, or having held, a different source-authoritative identifier
        \* than the one this update carries is not a match: the source-authoritative identifier
        \* decides, and the override is recorded (SourceAuthorityGuard.source_mismatch?/3, applied
        \* by BatchResolver.strong_match/2 and Resolver.lookup_governed_matches/3; #4611). A
        \* retired id keeps this veto (D2), so a MAC never attaches a new id to an old record, and
        \* the record a reported id was retired from is a match only by reactivation, which
        \* resolves the id as if that record still held it.
        srcMismatch(r) == srcS # {} /\ SrcHist(r) # {} /\ SrcHeld(r) \cap srcS = {}
        allM    == {Canon(owner[i]) : i \in {j \in S : owner[j] # NoRec}}
        M       == {r \in allM : ~srcMismatch(r)} \cup reactivated
        matched == {i \in S : owner[i] # NoRec /\ Canon(owner[i]) \in M}
                   \cup (IF reactivated # {} THEN retiredS ELSE {})
        named   == reissued /\ M = {} /\ created[Seed(strong)]
    IN
    \E X \in (IF M # {} THEN M ELSE {NoRec}),
       older \in (IF kind = "Arp" /\ strong # {} THEN BOOLEAN ELSE {FALSE}),
       fresh \in (IF named THEN {n \in Spare : ~created[n]} ELSE {NoRec}) :
    LET \* --- Step 1: strong-identifier conflict (merge_conflicting_devices/4) ---
        others     == M \ {X}
        conflictOk == others # {} /\ ~SrcConflict(M) /\ PolicyAllows(matched)
        step1Merged == IF conflictOk THEN {o \in others : ~DistinctAgents(o, X)} ELSE {}
        \* --- Fallback when nothing matched (resolve_fallback_device_id/3) ---
        holderAt == {r \in Recs : Live(r) /\ r \notin step1Merged /\ recIp[r] = p}
        target0 ==
            IF M # {} THEN X
            ELSE IF fresh # NoRec THEN fresh
            ELSE IF strong # {} THEN Canon(Seed(strong))
            ELSE LET weak == holderAt \cup {r \in alias[p] : Live(r)}
                 IN IF weak # {} THEN CHOOSE r \in weak : TRUE ELSE Canon(p)
        \* --- The device write and ocsf_devices_unique_active_ip_idx
        \*     (DeviceWrites.resolve_record_active_ip/7; for an existing device the mapper
        \*     polled, MapperResultsIngestor.move_device_address/4) ---
        others0   == holderAt \ {target0}
        seedHold  == {r \in others0 : IdsHeld(r) = {} /\ ArchivedOf(r) = {}}
        \* A strong write creating a new record onto an address held by an anchorless provisional
        \* seed adopts the seed. An existing record never does (#4705): it takes the address below
        \* and the seed releases it. A record holding only retired ids is anchored by them: the
        \* adoption check reads the archive too (D2), or another device's new id would adopt it.
        adopt     == strong # {} /\ ~created[target0] /\ seedHold # {}
        target    == IF adopt THEN CHOOSE r \in seedHold : TRUE ELSE target0
        \* An existing result whose address is still one of its own keeps it, and this write
        \* claims no address at all.
        keepAddr  == created[target] /\ recIp[target] \in keepIps
        \* An identity-bearing write at an address another live record holds: the address follows
        \* the device observed at it, so the holder releases it (its address is cleared) and the
        \* decision is recorded (DeviceWrites.claim_address_from_holder/5; #4639). D7: the holder
        \* releases it to a write observed after the holder, comparing identity_observed_at, which
        \* only identity-bearing observations advance (observed_after?/2); a holder with none is
        \* older. The model has no clock: a source sync, an agent check-in and a mapper poll are
        \* each the device's newest identity-bearing observation and always take the address (a
        \* retired holder also yields to a current source id, whatever the times). A census
        \* carries no time of its own, only its record's last identity-bearing one: with none it
        \* never displaces a holder that has one, and when both have one either may be newer
        \* (older). A holder that keeps the address leaves the write without one.
        rivals    == IF keepAddr THEN {} ELSE holderAt \ {target}
        \* A source write whose hostname agrees with a rival's: agreement may attach only a record
        \* that is not yet a device and carries no source-authoritative identifier, and a source
        \* write carries one, so adoption is refused and the pair is recorded for de-duplication
        \* review (DeviceWrites.adopt_on_hostname_agreement?/4), with telemetry beside the record.
        \* The model writes only the source's hostnames (recFs).
        hostRivals == IF kind = "Armis" THEN {y \in rivals : HostOf[h] \in HostsOf(recFs[y])} ELSE {}
        keptHeld  == IF kind = "Arp" /\ strong # {}
                     THEN {r \in rivals : idSeen[r] /\ (~idSeen[target] \/ older)}
                     ELSE {}
        holders   == rivals \ keptHeld
        ipConflict == strong # {} /\ rivals # {}
        \* D8: an anchorless provisional seed (no identifier, current or retired) that releases its
        \* only address to an identified device is soft-deleted in the same transaction, reason
        \* seed_released (DeviceWrites.lock_and_clear_for_upsert/3). The model writes that as the
        \* record no longer existing, so a later sweep of the address with no holder may seed it
        \* again at once. The code keeps the tombstone, whose address-derived uid makes that seed
        \* a duplicate until the purge: the model allows more than the code does. In every
        \* environment with a strong writer an anchorless record is a sweep seed: an address-only
        \* Arp or Discovery record needs a device with no globally-unique MAC (the phones
        \* environment, which has no strong writer).
        released  == IF strong # {} THEN {r \in holders : IdsHeld(r) = {} /\ ArchivedOf(r) = {}}
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
            \cup {[kind |-> "policy_block", recs |-> {target, y}] : y \in hostRivals}
            \cup (IF reactivated # {}
                  THEN {[kind |-> "source_id_reactivated", recs |-> reactivated \cup {target}]}
                  ELSE {})
            \cup (IF reissued THEN {[kind |-> "source_id_reissued", recs |-> heldBy \cup {target}]}
                  ELSE {})
        \* Every decision leaves a persisted identity decision (DecisionLog.record/4, #4613).
        recorded == decisions
        into2   == [r \in Recs |-> IF r \in step1Merged THEN target0
                               ELSE IF r \in step2Merged THEN target
                               ELSE into[r]]
        \* --- The alias sighting (AliasEvents.process_and_persist/2), after the alias pass ---
        \* A source sync and a census record a sighting of the address on an alias row
        \* (Sync.Aliases.process_alias_updates/2, which SyncIngestor runs after the alias
        \* conflicts), as a mapper result does for the address it polled. recordAlias is a sighting
        \* that reaches the confirmation threshold and confirms its row, the result's own.
        \* Rows are per device (DeviceAliasState.lookup_for_device/4): a sighting counts only toward
        \* the observed record's own row, and another device's row at the address is never touched.
        confirms == IF recordAlias THEN {target} ELSE {}
        owner2  == [i \in Ids |-> IF owner1[i] \in step2Merged THEN target ELSE owner1[i]]
        recIp2  == [r \in Recs |->
                      IF r = target THEN (IF keepAddr \/ keptHeld # {} THEN recIp[r] ELSE p)
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
                   \cup (IF q = p THEN confirms ELSE {})]
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
                   \cup (IF kind = "Armis" /\ r = target THEN {FsOf(h, a) : a \in srcS} ELSE {})
                   \cup (IF r = target0 THEN UNION {recFs[m] : m \in step1Merged} ELSE {})
                   \cup (IF r = target THEN UNION {recFs[m] : m \in step2Merged} ELSE {})]
    \* The sync is the source's latest sighting of the record's device, and every id the source has
    \* issued was first seen no later. A merged record was last seen at the later of the two.
    /\ seenWith' = [r \in Recs |->
                      seenWith[r]
                      \cup (IF kind = "Armis" /\ r = target THEN Issued ELSE {})
                      \cup (IF r = target0 THEN UNION {seenWith[m] : m \in step1Merged} ELSE {})
                      \cup (IF r = target THEN UNION {seenWith[m] : m \in step2Merged} ELSE {})]
    \* The write advances the record's identity_observed_at only when it is the device's own
    \* identity-bearing report (D7): never a census or an address-only poll. A merge leaves it
    \* as it was on the survivor (MergeEngine never writes it).
    /\ idSeen' = [r \in Recs |-> idSeen[r] \/ (r = target /\ kind # "Arp" /\ S # {})]
    /\ archive' = [a \in SrcIds |->
                     IF a \in retiredS THEN {q \in archive[a] : Canon(q) \notin reactivated}
                     ELSE archive[a]]
    /\ UNCHANGED <<ipAt, srcOf, absence>>

\* Armis sync: the Armis device id, plus the device's MACs when Armis reports them. Its update
\* carries a non-MAC identifier, so Sync.Aliases.process_alias_conflicts/2 runs.
\* The pass looks the address's alias up under the device's partition, where AliasEvents records it.
ArmisObserve(h, x) ==
    /\ srcOf[h] # NoId /\ IfPhys[x] = h /\ ipAt[x] # NoIp
    /\ \E ra \in BOOLEAN :
         Resolve(h, x, {srcOf[h]} \cup (IF ArmisMacs THEN MacsOf(h) ELSE {}), ra,
                 "sync", "Armis", {}, {})

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
\* and availability and nothing else: a sweep never writes or moves an address, never merges and
\* never advances identity_observed_at (D7). An address nothing holds gets a provisional record
\* seeded from it (create_available_unknown_devices/5); its uid derives from the address, so a
\* record already named by the address that holds it no longer -- merged away, or one that
\* released it and stayed live -- makes the create a duplicate, which is skipped.
SweepObserve(h, x) ==
    LET p        == ipAt[x]
        aliasAt  == {r \in alias[p] : Live(r)}
        holderAt == {r \in Recs : Live(r) /\ recIp[r] = p}
        seen     == IF aliasAt # {} THEN aliasAt ELSE holderAt
    IN
    /\ IfPhys[x] = h /\ p # NoIp
    /\ \/ seen # {} /\ UNCHANGED <<created, recIp>>
       \/ /\ seen = {} /\ ~created[p]
          /\ created' = [created EXCEPT ![p] = TRUE]
          /\ recIp' = [recIp EXCEPT ![p] = p]
    /\ act' = [name |-> "Sweep", ids |-> {}, ip |-> p, decisions |-> {}, recorded |-> {},
               addressMerged |-> {}]
    /\ UNCHANGED <<ipAt, into, owner, alias, phys, ifClaims, srcOf, absence, archive,
                   recFs, idSeen, seenWith>>

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
    \* An id issued now is first seen after every record's last sighting, a re-issued one too.
    /\ seenWith' = IF a = NoId THEN seenWith ELSE [r \in Recs |-> seenWith[r] \ {a}]
    /\ act' = [name |-> "Rekey", ids |-> {}, ip |-> NoIp, decisions |-> {}, recorded |-> {},
               addressMerged |-> {}]
    /\ UNCHANGED <<ipAt, created, into, owner, recIp, alias, phys, ifClaims, archive,
                   recFs, idSeen>>

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
    /\ UNCHANGED <<ipAt, created, into, owner, recIp, alias, phys, ifClaims, srcOf,
                   archive, recFs, idSeen, seenWith>>

\* The retirement job an activation enqueues (D1, Identity.SourceRetirement.run/2): a stale id
\* leaves device_identifiers for the archive, remembering the record that held it, and the
\* decision is recorded.
\*   Unsafe retired_ids_forgotten: retirement drops the identifier without archiving it, so
\*       nothing remembers that the record held it.
RetireAbsent(a) ==
    /\ absence[a] = "Stale" /\ owner[a] # NoRec
    /\ owner' = [owner EXCEPT ![a] = NoRec]
    /\ archive' = IF "retired_ids_forgotten" \in Unsafe THEN archive
                  ELSE [archive EXCEPT ![a] = @ \cup {owner[a]}]
    /\ LET d == {[kind |-> "source_id_retired", recs |-> {owner[a]}]} IN
       act' = [name |-> "Retire", ids |-> {}, ip |-> NoIp, decisions |-> d, recorded |-> d,
               addressMerged |-> {}]
    /\ UNCHANGED <<ipAt, created, into, recIp, alias, phys, ifClaims, srcOf, absence,
                   recFs, idSeen, seenWith>>

\* The reconciler's succession pass. A predecessor holds only retired source ids; a successor
\* holds a current one (D3).
Pred(r) == Live(r) /\ SrcHeld(r) = {} /\ ArchivedOf(r) # {}
Succ(r) == Live(r) /\ SrcHeld(r) # {}
\* MACs both records report that link the predecessor to no other current record.
LinkMacs(pr, sc) ==
    {m \in MacEv(pr) \cap MacEv(sc) : \A r \in Recs \ {sc} : Succ(r) => m \notin MacEv(r)}
\* The predecessor's last source observation and the successor's current one corroborate.
Corroborated(pr, sc) == CorroboratedBy(pr, recFs[sc], SrcHeld(sc))
\* A pair the evidence names: a linking MAC and, when corr, corroboration.
Paired(pr, sc, corr) ==
    Pred(pr) /\ Succ(sc) /\ LinkMacs(pr, sc) # {} /\ (corr => Corroborated(pr, sc))
\* D3: the pairing is one-to-one in both directions, and no distinct assertion covers it (distinct
\* agents: MergeEngine.merge_guard_violation/4).
Successive(pr, sc, corr) ==
    /\ Paired(pr, sc, corr)
    /\ \A r \in Recs \ {sc} : ~Paired(pr, r, corr)
    /\ \A q \in Recs \ {pr} : ~Paired(q, sc, corr)
    /\ ~DistinctAgents(pr, sc)
\*   Unsafe mac_only_succession: a linking MAC alone converges the pair.
SuccCorr == "mac_only_succession" \notin Unsafe
Succession(pr, sc) == Successive(pr, sc, SuccCorr)

\* The succession merge, reason source_succession. The record created first survives, usually the
\* predecessor; the model does not order creation, so either may. The survivor holds the current
\* id and takes the successor's address when the successor holds one, and the merged record's
\* alias rows (DeviceAliasState.reassign_device). The merge is not an identity decision.
Succeed(pr, sc) ==
    /\ Succession(pr, sc)
    /\ \E s \in {pr, sc} :
         LET m == IF s = pr THEN sc ELSE pr IN
         /\ into' = [into EXCEPT ![m] = s]
         /\ owner' = [i \in Ids |-> IF owner[i] = m THEN s ELSE owner[i]]
         /\ recIp' = [recIp EXCEPT ![s] = IF recIp[sc] # NoIp THEN recIp[sc] ELSE recIp[s]]
         /\ alias' = [q \in Ips |-> IF m \in alias[q] THEN (alias[q] \ {m}) \cup {s} ELSE alias[q]]
         /\ phys' = [phys EXCEPT ![s] = @ \cup phys[m]]
         /\ ifClaims' = [ifClaims EXCEPT ![s] = @ \cup ifClaims[m]]
         /\ recFs' = [recFs EXCEPT ![s] = @ \cup recFs[m]]
         /\ seenWith' = [seenWith EXCEPT ![s] = @ \cup seenWith[m]]
    /\ act' = [name |-> "Succession", ids |-> {}, ip |-> NoIp, decisions |-> {}, recorded |-> {},
               addressMerged |-> {}]
    /\ UNCHANGED <<ipAt, created, srcOf, absence, archive, idSeen>>

\* The other records a review of the pair names (SourceSuccession.classify/1): for a pairing that
\* is not one-to-one, every record paired with either; for a MAC that links the predecessor to
\* another current record, every current record reporting a MAC the two share.
Rivals(pr, sc) ==
    IF Paired(pr, sc, SuccCorr)
    THEN {r \in Recs \ {pr, sc} : Paired(pr, r, SuccCorr) \/ Paired(r, sc, SuccCorr)}
    ELSE IF LinkMacs(pr, sc) = {}
         THEN {r \in Recs \ {pr, sc} : Succ(r) /\ MacEv(r) \cap MacEv(pr) \cap MacEv(sc) # {}}
         ELSE {}

\* D4: weaker evidence never merges. The pair gets a succession_review decision, naming its
\* rivals, which opens a de-duplication task: a MAC only, a MAC linking the predecessor to another
\* current record, a pairing that is not one-to-one, or, without a MAC, agreement on both the
\* hostname and the first-seen time (a first-seen time names the device in the model, FsOf). A
\* hostname alone, without a MAC, records nothing. Distinct agents rule the pair out, as for a
\* succession.
Review(pr, sc) ==
    /\ Pred(pr) /\ Succ(sc)
    /\ MacEv(pr) \cap MacEv(sc) # {} \/ recFs[pr] \cap recFs[sc] # {}
    /\ ~Succession(pr, sc)
    /\ ~DistinctAgents(pr, sc)
    /\ LET d == {[kind |-> "succession_review", recs |-> {pr, sc} \cup Rivals(pr, sc)]} IN
       act' = [name |-> "Review", ids |-> {}, ip |-> NoIp, decisions |-> d, recorded |-> d,
               addressMerged |-> {}]
    /\ UNCHANGED <<ipAt, created, into, owner, recIp, alias, phys, ifClaims, srcOf,
                   absence, archive, recFs, idSeen, seenWith>>

Next ==
    \/ \E x \in Ifaces, p \in Ips \cup {NoIp} : Lease(x, p)
    \/ \E h \in Phys, a \in SrcIds \cup {NoId} : Rekey(h, a)
    \/ Collect
    \/ \E a \in SrcIds : RetireAbsent(a)
    \/ \E pr, sc \in Recs : Succeed(pr, sc) \/ Review(pr, sc)
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
\* the record it landed on holds the observed address. A census carries no identity-bearing time
\* of its own, so after one the address may instead stay with a holder whose identity was
\* observed (D7).
ObservedAddressHeld ==
    [][(act'.name \in {"Armis", "Arp", "Agent"} /\ act'.ids # {}) =>
         \E r \in Recs : /\ created'[r] /\ into'[r] = NoRec /\ recIp'[r] = act'.ip
                         /\ \/ act'.ids \cap HeldIn(owner', r, Ids) # {}
                            \/ act'.name = "Arp" /\ idSeen'[r]]_vars

\* IP Alias Resolution; IP Alias Sightings and Promotion: after a source sync observes a device at
\* an address, every identified record keeping a confirmed alias of the address describes that
\* device. Another device's identified record has the alias invalidated, and no other device's
\* sighting confirms one. Checked after source syncs only: a census runs no alias pass, and
\* AliasGuard runs only on the resolver's strong-match branch.
AliasFollowsSyncedDevice ==
    [][act'.name = "Armis" =>
         \A x \in Ifaces, y \in Recs :
           (/\ ipAt'[x] = act'.ip /\ y \in alias'[act'.ip]
            /\ created'[y] /\ into'[y] = NoRec /\ HeldIn(owner', y, Ids) # {})
           => IfPhys[x] \in phys'[y]]_vars

\* Randomized MACs Are Evidence Only: no record is identified by a randomized MAC. A record is
\* named by the identifier its uid was derived from, so a record named by one is identified by it.
RandomizedMacsNeverIdentify == \A m \in LaaIds : ~created[m]

\* Identity Decisions Are Never Silent.
NoSilentDecision == [][act'.decisions \subseteq act'.recorded]_vars

---------------------------------------------------------------------------
(* Properties -- source identifier change (add-source-id-succession) *)

\* Source ids a record still holds that the source no longer reports.
AbsentHeld == {a \in SrcIds : owner[a] # NoRec /\ a \notin CurrentIds}
\* A retirement the next job would still make, and a succession the reconciler would still make.
PendingRetirement == \E a \in AbsentHeld : absence[a] = "Stale"
PendingSuccession == \E pr, sc \in Recs : Succession(pr, sc)
\* At rest: every id the source stopped reporting has been absent long enough to retire, and
\* neither the retirement job nor the reconciler would change anything.
AtRest ==
    /\ \A a \in AbsentHeld : absence[a] = "Stale"
    /\ ~PendingRetirement
    /\ ~PendingSuccession

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

\* Retired Source Identifiers Converge Only With Corroboration: every source_succession merge
\* joined a pair linked by a MAC, corroborated and paired one-to-one. A MAC alone never merges.
SuccessionIsCorroborated ==
    [][act'.name = "Succession" =>
         \A r \in Recs : into[r] = NoRec /\ into'[r] # NoRec =>
           \E pr, sc \in {r, into'[r]} : pr # sc /\ Successive(pr, sc, TRUE)]_vars

\* No live record holds neither an identifier nor an address. A record holding only retired ids is
\* marked source_retired by its retirement and deleted after the grace period (D5, modeled in
\* DireLifecycle), so it is not a shell here.
NoAddresslessShell ==
    \A r \in Recs : Live(r) /\ ArchivedOf(r) = {} => IdsHeld(r) # {} \/ recIp[r] # NoIp

=============================================================================
