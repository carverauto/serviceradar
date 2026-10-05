------------------------- MODULE MCDireLifecycle -------------------------
(* TLC harness: symmetry and a view that drops the act history variable. *)
EXTENDS DireLifecycle, CurrentBugs, TLC
\* A MAC identifier is told apart from the others, so only source and agent ids are permuted.
Symmetry == Permutations(Devices) \cup Permutations(Ids \ MacIds) \cup Permutations(Ips)
StateView == <<status, reason, owner, ipOf, audit, work, marked, arch, sweepOnly>>
\* Vacuity: the model can expire a device. ExpiryKeepsStrongIdentity would pass vacuously if it
\* could not (lifecycle_vacuity_expire expects this property to fail).
NeverExpires == [][act'.name # "Expire"]_vars
\* Vacuity: the model can grace-delete a retired record, so MarkedHoldsOnlyMacs and
\* RetiredTombstoneStaysDeleted have a tombstone to judge (lifecycle_vacuity_grace_delete).
NeverGraceDeletes == [][act'.name # "GraceDelete"]_vars
\* Vacuity: the record grace-deleted may still hold a MAC, which neither withholds nor clears the
\* mark (lifecycle_vacuity_grace_delete_mac).
NeverGraceDeletesMacHolder ==
    [][~(act'.name = "GraceDelete" /\ \E i \in MacIds : owner[i] = act'.u)]_vars
\* Vacuity: a returning retired id restores a grace-deleted record, the path
\* RetiredTombstoneStaysDeleted allows (lifecycle_vacuity_reactivate).
NeverReactivatesRetired ==
    [][~\E u \in Devices :
          /\ status[u] = "tomb" /\ reason[u] = "source_retired" /\ status'[u] = "live"
          /\ act'.name = "Reactivate"]_vars
\* Vacuity: a sweep restores an expired sweep-only tombstone, the case ExpiredDeviceReturns is
\* about (lifecycle_vacuity_expired_returns).
NeverRestoresExpired ==
    [][~(act'.name = "SweepRestore" /\ reason[act'.u] = "expired" /\ act'.u \in sweepOnly)]_vars
=============================================================================
