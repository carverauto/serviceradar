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
\* vacuity: no identity decision is ever made
NeverDecides == [][act'.decisions = {}]_vars
\* vacuity: Armis and discovery never converge on one record
NeverConverged == ~\E r \in Recs : owner["a1"] = r /\ owner["m1"] = r
=============================================================================
