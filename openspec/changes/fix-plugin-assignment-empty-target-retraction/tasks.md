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

## 3. Follow-up: owner lifecycle retraction
- [x] 3.1 Retract a credential rule's or target policy's enabled assignments in the owner's own disable, delete, and scope-narrowing actions (the periodic workers never reconcile such owners), recording the reason and the acting operator on the assignment (`disabled_reason`, `disabled_by`, `disabled_at`, migration `20261021044625`).
- [x] 3.2 Report pre-existing orphans (owner missing, disabled, or out of scope) with owner, agent, plugin and package, and retract a selected set or all of them with the reason `orphaned_owner_cleanup`; never disable them from a migration or periodic job.
- [x] 3.3 Surface the orphan report and a Retract action on the plugins page for operators with `settings.plugins.manage`.

## 4. Follow-up tests
- [x] 4.1 Disabling, deleting, and narrowing a credential rule retract its assignments and record actor and reason.
- [x] 4.2 Disabling, deleting, and narrowing a target policy do the same.
- [x] 4.3 The orphan listing finds pre-existing orphans and skips covered, live and foreign-owner assignments.
- [x] 4.4 Cleanup retracts only selected current orphans, records the reason, and requires plugin management.
- [x] 4.5 Neither periodic reconcile worker disables an orphan.
- [x] 4.6 LiveView: the needs-attention report lists an orphan and retracts it; a viewer without plugin management sees neither.
