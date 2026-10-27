## 1. Convergence

- [x] 1.1 Migration `20261026220000_converge_merged_availability`: seed missing compatibility rows in `legacy`/`shadow`, enqueue `ReconcileWorker`, drop the mirror and legacy-update triggers, make the invalidation triggers unconditional, drop the shadow table, the mode and control columns and `availability_mode()`, start the expiry watermark, delete waiting jobs of the retired workers. Helm `core.migrations.expectedVersion` bumped.
- [x] 1.2 `ReconcileWorker`: full resolve, rollup rebuild, and the one summary plus recoveries for an install that was not yet `authoritative`.
- [x] 1.3 `Resolution`: no mode; a device's first merged decision after `legacy_mirror` emits no transition.

## 2. Removal

- [x] 2.1 Core: `Mode`, `ModeControl`, `ProgressionWorker`, `Readiness`, `ShadowEntryWorker`, `CaptureBackfillWorker`, `CutoverWorker`, `DivergenceReport`, `ShadowDecision`, `Setting`, the `Operator` switch/control/status/report and the two Mix tasks; the progression cron entries and the mode-control pin config.
- [x] 2.2 Writers (sweep, sync, check-in, camera, composite checks) write only the compatibility store; the legacy transition publishers (`SweepJobs.AvailabilityEvents`, the sync `is_available` state event) are removed.
- [x] 2.3 web-ng: the rollout panel; the Armis preview's shadow-mode guard and mode copy.
- [x] 2.4 Helm: `core.availability.modeControl` and `SERVICERADAR_AVAILABILITY_MODE_CONTROL`.
- [x] 2.5 Docs: `docs/merged-device-availability.md` replaces the cutover runbook.

## 3. Tests

- [x] 3.1 Remove the mode, progression and rollback tests.
- [x] 3.2 Upgrade from `legacy`, `shadow` and `authoritative`: badge, order and count read merged values; a `legacy`-semantics Armis source pushes identical values; agent-selected candidates and per-agent rows are identical; a device created after the upgrade gets a compatibility row.
- [x] 3.3 `openspec validate simplify-merged-availability-rollout --strict`.
