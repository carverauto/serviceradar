## 1. Design
- [ ] 1.1 Inventory current database clients, pools, queue widths, scheduler loops, and major DB-backed workload classes across `core-elx` and `web-ng`.
- [ ] 1.2 Define workload classes that distinguish control-plane critical paths from maintenance, enrichment, reconciliation, and analytics batch work.
- [ ] 1.3 Choose the isolation model for those classes, including separate repos/pools or an equivalent mechanism that preserves reserved DB capacity for critical workflows.
- [ ] 1.4 Define concurrency-governance rules so Oban queue widths, scheduler throughput, and worker fan-out are budgeted against actual DB capacity.

## 2. Runtime Architecture
- [x] 2.1 Implement the chosen DB workload-isolation model in `serviceradar_core`.
- [ ] 2.2 Move background job execution and scheduler-owned maintenance work onto the governed background budget.
- [ ] 2.3 Keep interactive/control-plane workflows on the protected control-plane budget, including MTR command persistence, status ingestion, heartbeat writes, auth, and operator-triggered reads/mutations.
  - Initial implementation moves MTR command dispatch, lifecycle status writes, and bulk target persistence onto the protected control repo.
- [ ] 2.4 Ensure optional subsystems can stay enabled without starving critical workflows when idle or lightly loaded.

## 3. Deployment Profiles
- [x] 3.1 Update Docker Compose defaults so the standard stack runs with all major subsystems enabled and a sane workload budget for single-node operation.
- [x] 3.2 Ensure larger deployment profiles can scale by explicit budget changes instead of inheriting unsafe queue and pool defaults.
- [ ] 3.3 Document the supported tuning model for DB pools, queue widths, and workload-class budgets.

## 4. Validation
- [ ] 4.1 Add telemetry and observability that expose pool utilization, queue pressure, and workload-class contention.
- [ ] 4.2 Add automated validation for critical workflows under concurrent background load, including MTR bulk/manual jobs, heartbeat/status persistence, and analytics page loading.
- [ ] 4.3 Prove the Docker Compose stack remains healthy and interactive after clean startup with major subsystems enabled.
- [x] 4.4 Run `openspec validate refactor-control-plane-db-workload-isolation --strict`.
