------------------------- MODULE MCDireLifecycle -------------------------
(* TLC harness: symmetry and a view that drops the act history variable. *)
EXTENDS DireLifecycle, CurrentBugs, TLC
Symmetry == Permutations(Devices) \cup Permutations(Ids) \cup Permutations(Ips)
StateView == <<status, reason, owner, ipOf, audit, work>>
\* Vacuity: the model can expire a device. ExpiryKeepsStrongIdentity would pass vacuously if it
\* could not (lifecycle_vacuity_expire expects this property to fail).
NeverExpires == [][act'.name # "Expire"]_vars
=============================================================================
