## 1. Update SweepCompiler to use SRQL for target extraction
- [ ] 1.1 Refactor `get_targets_from_criteria/3` to use SRQL instead of loading all devices and filtering in-memory.
- [ ] 1.2 Execute `in:devices {criteria_query} select:ip` to get target IPs directly.
- [ ] 1.3 Extract `criteria_to_srql_query/1` logic into shared module (e.g., `ServiceRadar.SweepJobs.CriteriaQuery`).

## 2. Add config refresh on device changes
- [ ] 2.1 Create `SweepConfigRefreshWorker` Oban job that runs periodically (default 5 min).
- [ ] 2.2 For each tenant's enabled sweep groups, execute SRQL query and compute hash of result IPs.
- [ ] 2.3 Store `target_hash` on SweepGroup or ConfigInstance.
- [ ] 2.4 If hash changed, invalidate config cache via `ConfigPublisher.publish_resource_change/5`.
- [ ] 2.5 Add Oban cron configuration for the worker.

## 3. Verify targeting rules UI coverage
- [ ] 3.1 Confirm all TargetCriteria operators are available in the sweep group targeting rules UI.
- [ ] 3.2 Confirm device fields are exposed (partition, discovery_sources, tags, ip, hostname, etc.).

## 4. Verify SRQL conversion
- [ ] 4.1 Ensure `criteria_to_srql_query` handles all TargetCriteria operators consistently.
- [ ] 4.2 Test that preview counts match actual compiled target lists.

## 5. Documentation
- [ ] 5.1 Update SRQL documentation to clarify that stacked filters use AND semantics.
- [ ] 5.2 Document the end-to-end flow from UI → SRQL → compiled config → agent sweep.
- [ ] 5.3 Document the config refresh mechanism and its interval.
