------------------------ MODULE MCDireResolution ------------------------
(* Environments for DireResolution: which physical world TLC explores. *)
EXTENDS DireResolution
\* two devices, one interface each
TwoIfPhys   == [x \in {"x1", "x2"} |-> IF x = "x1" THEN "h1" ELSE "h2"]
TwoHwMacs   == [x \in {"x1", "x2"} |-> IF x = "x1" THEN "m1" ELSE "m2"]
TwoLaaMacs  == [x \in {"x1", "x2"} |-> IF x = "x1" THEN "r1" ELSE "r2"]
BothArmis   == [h \in {"h1", "h2"} |-> IF h = "h1" THEN "a1" ELSE "a2"]
OneArmis    == [h \in {"h1", "h2"} |-> IF h = "h1" THEN "a1" ELSE NoId]
NoArmis2    == [h \in {"h1", "h2"} |-> NoId]
NoAgents2   == [h \in {"h1", "h2"} |-> NoId]
\* h2 runs an agent (agent gateway check-ins)
AgentOnH2   == [h \in {"h1", "h2"} |-> IF h = "h2" THEN "g2" ELSE NoId]
\* a router alone: two interfaces, two MACs
RouterOnlyIfPhys == [x \in {"x1", "x2"} |-> "h1"]
NoArmis1    == [h \in {"h1"} |-> NoId]
NoAgents1   == [h \in {"h1"} |-> NoId]
AgentOnH1   == [h \in {"h1"} |-> "g1"]
\* two Armis devices reporting the same MAC (cloned VMs, a swapped NIC)
SharedMac   == [x \in {"x1", "x2"} |-> "m1"]
\* one device with one interface, which the source may re-identify
OneIfPhys   == [x \in {"x1"} |-> "h1"]
OneHwMac    == [x \in {"x1"} |-> "m1"]
ArmisA1     == [h \in {"h1"} |-> "a1"]
\* every device reports its own hostname
OwnHost     == [h \in Phys |-> h]
\* cloned machines: every device reports the same hostname
OneHost     == [h \in Phys |-> "n1"]
SharedHost  == \E k1, k2 \in Phys : k1 # k2 /\ HostOf[k1] = HostOf[k2]
\* Hostnames can agree where first-seen times do not: two devices share a hostname, or a re-key
\* gives a device a new first-seen time.
HostnameAlone == SharedHost \/ NewFirstSeenIds # {}
\* act is a history variable Next never reads. Next reads recFs only for a record holding a
\* retired id, and the archive stays empty unless Rekeys; it reads addrFresh only under
\* stale_holder_keeps_address, and aliasRow only under foreign_sighting_confirms_alias. It reads
\* seenWith only where hostnames agree and first-seen times do not (HostnameAlone), and only for
\* a record holding a retired id. Leaving them out of the fingerprint otherwise is sound.
StateView == <<ipAt, created, into, owner, recIp, alias, phys, ifClaims, srcOf, absence, archive,
               IF Rekeys THEN recFs ELSE <<>>,
               IF Bug("stale_holder_keeps_address") THEN addrFresh ELSE <<>>,
               IF Bug("foreign_sighting_confirms_alias") THEN aliasRow ELSE <<>>,
               IF Rekeys /\ HostnameAlone THEN seenWith ELSE <<>>>>
\* vacuity: nothing is ever merged
NeverMerged == \A r \in Recs : into[r] = NoRec
\* vacuity: no identity decision is ever made
NeverDecides == [][act'.decisions = {}]_vars
\* vacuity: the reconciler never merges a re-keyed pair
NeverSucceeds == [][act'.name # "Succession"]_vars
\* vacuity: Armis and discovery never converge on one record
NeverConverged == ~\E r \in Recs : owner["a1"] = r /\ owner["m1"] = r
=============================================================================
