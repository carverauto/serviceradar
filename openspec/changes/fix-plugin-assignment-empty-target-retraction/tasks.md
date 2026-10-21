## 1. Implementation
- [x] 1.1 Hold stale retraction in `PolicyAssignmentReconciler` when an enabled policy resolves zero target rows; report `held` and `hold_reason: :targets_unresolved`, log a warning naming the policy and agents, and emit telemetry.
- [x] 1.2 Keep retraction for a disabled policy and for a non-empty resolution that excludes an assignment.
- [x] 1.3 Opt the AWX inventory-sync reconciler out, since its controller list is authoritative.
- [x] 1.4 Report a held credential rule as the `targets_unresolved` skip reason in the materializer summary.

## 2. Tests
- [x] 2.1 Reconciler: an empty resolution keeps enabled rows and reports `:targets_unresolved` (fails on the pre-change code).
- [x] 2.2 Reconciler: a non-empty resolution that excludes a row still disables it.
- [x] 2.3 Reconciler: a disabled policy still retracts on an empty resolution.
- [x] 2.4 Materializer: a held result is reported as the `targets_unresolved` skip.
- [x] 2.5 Reconciler: an empty resolution whose only assignment is already disabled reports `held: 0` with `:targets_unresolved` and does not re-enable the row.

## 3. Follow-up
- [ ] 3.1 Retract a credential rule's assignments when the rule is disabled, deleted, or no longer scoped to the agent (the periodic workers never reconcile such rules).
