------------------------- MODULE MCDireLifecycle -------------------------
(* TLC harness: symmetry and a view that drops the act history variable. *)
EXTENDS DireLifecycle, CurrentBugs, TLC
Symmetry == Permutations(Devices) \cup Permutations(Ids) \cup Permutations(Ips)
StateView == <<status, reason, owner, ipOf, audit, work, marked, arch, sweepOnly>>
\* Vacuity: the model can expire a device. ExpiryKeepsStrongIdentity would pass vacuously if it
\* could not (lifecycle_vacuity_expire expects this property to fail).
NeverExpires == [][act'.name # "Expire"]_vars
\* Vacuity: the model can grace-delete a retired record, so MarkedHoldsNoIdentifier and
\* RetiredTombstoneStaysDeleted have a tombstone to judge (lifecycle_vacuity_grace_delete).
NeverGraceDeletes == [][act'.name # "GraceDelete"]_vars
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
