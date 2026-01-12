## 1. Update SweepCompiler to use SRQL for target extraction
- [x] 1.1 Refactor `get_targets_from_criteria/3` to use Ash filters at database level (with fallback for complex operators).
- [x] 1.2 Created `TargetCriteria.to_ash_filter_with_fallback/1` to split criteria into Ash-supported and unsupported.
- [x] 1.3 Extract `criteria_to_srql_query/1` logic into shared module `ServiceRadar.SweepJobs.CriteriaQuery`.

## 2. Target list updates
- [x] 2.1 Confirmed: SweepCompiler computes targets fresh on each agent config poll.
- [x] 2.2 No additional refresh mechanism needed - agents get current targets automatically.
- **Note:** Config refresh worker was removed due to tenant isolation concerns (Oban jobs must be tenant-scoped).
- [x] 2.3 Converted workers to tenant-scoped TenantWorker pattern:
  - SweepMonitorWorker - now scheduled per-tenant when sweep groups are enabled
  - SweepDataCleanupWorker - now scheduled per-tenant when sweep groups are enabled
  - StatefulAlertCleanupWorker - now scheduled per-tenant when alert rules are created

## 3. Verify targeting rules UI coverage
- [x] 3.1 Confirm all TargetCriteria operators are available in the sweep group targeting rules UI.
  - UI exposes all TargetCriteria operators except `is_null`/`is_not_null` (rarely needed for sweep targeting)
  - Operators by field type: text (8), tags (2), discovery_sources (4), ip (6), boolean (2), numeric (6)
- [x] 3.2 Confirm device fields are exposed (discovery_sources, tags, ip, hostname, etc.).
  - 20 device fields exposed: tags, discovery_sources, hostname, ip, mac, uid, gateway_id, agent_id, etc.
  - Note: `partition` is on DeviceIdentifier, not Device - not currently exposed (future enhancement)

## 4. Verify SRQL conversion
- [x] 4.1 Ensure `CriteriaQuery.to_srql` handles all TargetCriteria operators consistently.
  - All operators handled: eq, neq, in, not_in, contains, not_contains, starts_with, ends_with
  - IP operators: in_cidr, not_in_cidr, in_range
  - Tags: has_any, has_all (with OR/AND grouping)
  - Numeric: gt, gte, lt, lte
  - Null operators return nil (not translatable to SRQL filter syntax - acceptable)
- [ ] 4.2 Test that preview counts match actual compiled target lists.
  - **Manual testing required**: Run sweep group UI with real device data, verify preview count matches compiled targets.

## 5. Documentation
- [x] 5.1 Update SRQL documentation to clarify that stacked filters use AND semantics.
  - Added "Core Semantics" section to `openspec/specs/srql/spec.md`
  - Documents implicit AND behavior and query builder integration
- [x] 5.2 Document the end-to-end flow from UI → SRQL → compiled config → agent sweep.
  - Flow diagram in `design.md` shows 6-step process
  - Updated step 3 to reflect Ash filters (not SRQL) for target extraction
- [x] 5.3 Documented target list update mechanism.
  - SweepCompiler computes fresh targets on each poll - no additional mechanism needed

## 6. Code cleanup
- [x] 6.1 Update networks_live to use shared `CriteriaQuery` module.
- [x] 6.2 Remove duplicate SRQL conversion code from networks_live.
