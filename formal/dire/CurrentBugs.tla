----------------------------- MODULE CurrentBugs -----------------------------
(***************************************************************************)
(* The defect switches today's code still has: the one place they are      *)
(* listed. Every recorded trace (traces/*.cfg) and lifecycle_current.cfg   *)
(* reads its Bugs constant from here.                                       *)
(*                                                                          *)
(* A fix removes its switch from this file and from the model's KnownBugs. *)
(* The models ASSUME Bugs \subseteq KnownBugs, so a switch left here after *)
(* it leaves KnownBugs fails every check that uses it. A lifecycle trace's *)
(* knockout (Trace_<name>__knockout.cfg) is this set minus the switch the  *)
(* trace demonstrates; once the switch is gone the two sets are equal, TLC *)
(* matches the trace under the knockout, and its target fails until the    *)
(* knockout is deleted.                                                     *)
(***************************************************************************)

ResolutionBugs == {
    "mac_only_conflicts_blocked",
    "mapper_resolves_by_address",
    "silent_blocks",
    "src_attach_via_mac",
    "stale_holder_keeps_address"
}

LifecycleBugs == {
    "fence_observe_only"
}

=============================================================================
