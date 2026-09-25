------------------------- MODULE MCDireLifecycle -------------------------
(* TLC harness: symmetry and a view that drops the act history variable. *)
EXTENDS DireLifecycle, CurrentBugs, TLC
Symmetry == Permutations(Devices) \cup Permutations(Ids) \cup Permutations(Ips)
StateView == <<status, reason, owner, ipOf, audit, work>>
=============================================================================
