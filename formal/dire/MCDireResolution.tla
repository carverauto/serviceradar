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
\* act is a history variable Next never reads; leaving it out of the fingerprint is sound
StateView == <<ipAt, created, into, owner, recIp, alias, phys, ifClaims>>
\* vacuity: nothing is ever merged
NeverMerged == \A r \in Recs : into[r] = NoRec
\* vacuity: no identity decision is ever made
NeverDecides == [][act'.decisions = {}]_vars
\* vacuity: Armis and discovery never converge on one record
NeverConverged == ~\E r \in Recs : owner["a1"] = r /\ owner["m1"] = r
=============================================================================
