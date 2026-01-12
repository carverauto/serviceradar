## 1. Update SweepCompiler to use SRQL for target extraction
- [x] 1.1 Refactor `get_targets_from_criteria/3` to use Ash filters at database level (with fallback for complex operators).
- [x] 1.2 Created `TargetCriteria.to_ash_filter_with_fallback/1` to split criteria into Ash-supported and unsupported.
- [x] 1.3 Extract `criteria_to_srql_query/1` logic into shared module `ServiceRadar.SweepJobs.CriteriaQuery`.

## 2. Add config refresh on device changes
- [x] 2.1 Create `SweepConfigRefreshWorker` Oban job that runs periodically (every 5 min).
- [x] 2.2 For each tenant's enabled sweep groups, compute hash of target IPs.
- [x] 2.3 Store `target_hash` and `target_hash_updated_at` on SweepGroup.
- [x] 2.4 If hash changed, invalidate config cache via `ConfigPublisher.publish_resource_change/5`.
- [x] 2.5 Add Oban cron configuration for the worker (`config_refresh` queue).
- [x] 2.6 Add database migration for target_hash columns.

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
- [x] 5.3 Document the config refresh mechanism and its interval.
  - Detailed implementation in "Config Invalidation on Device Changes" section
  - Covers: 5-minute cron interval, hash computation, change logging

## 6. Code cleanup
- [x] 6.1 Update networks_live to use shared `CriteriaQuery` module.
- [x] 6.2 Remove duplicate SRQL conversion code from networks_live.
