----------------------------- MODULE CurrentBugs -----------------------------
(***************************************************************************)
(* The defect switches today's code still has: the one place they are      *)
(* listed. Every recorded trace (traces/*.cfg) and lifecycle_current.cfg   *)
(* reads its Bugs constant from here.                                       *)
(*                                                                          *)
(* A fix removes its switch from this file and from the model's KnownBugs. *)
(* The models ASSUME Bugs \subseteq KnownBugs, so a switch left here after *)
(* it leaves KnownBugs fails every check that uses it. A trace's knockout  *)
(* (Trace_<name>__knockout.cfg) is this set minus the switch the           *)
(* trace demonstrates; once the switch is gone the two sets are equal, TLC *)
(* matches the trace under the knockout, and its target fails until the    *)
(* knockout is deleted.                                                     *)
(***************************************************************************)

ResolutionBugs == {"retired_source_id_vetoes", "stale_holder_keeps_address",
                   "released_seed_stays_live", "armis_alias_pass_blind",
                   "foreign_sighting_confirms_alias"}

LifecycleBugs == {"sweep_refreshes_expired_tombstone"}

=============================================================================
