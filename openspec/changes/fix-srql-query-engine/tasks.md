# Tasks: Fix SRQL Query Engine

## 1. Fix TimeFilterSpec Serialization (Rust)

- [ ] 1.1 Review current serde attributes in `rust/srql/src/time.rs`
- [ ] 1.2 Add unit test that serializes TimeFilterSpec::RelativeHours to JSON
- [ ] 1.3 If adjacently-tagged fails, switch to struct variants or externally-tagged
- [ ] 1.4 Rebuild NIF with `mix compile` and verify parse_ast works
- [ ] 1.5 Test query `in:devices time:last_24h` works without serialization error

## 2. Fix Quick Filter URLs (UI)

- [ ] 2.1 Update Available filter in `device_live/index.ex` to `in:devices is_available:true`
- [ ] 2.2 Update Unavailable filter to `in:devices is_available:false`
- [ ] 2.3 Update Swept filter to `in:devices discovery_sources:(sweep)`
- [ ] 2.4 Test all quick filters work from UI

## 3. Add LIKE Operator to Ash Adapter

- [ ] 3.1 Add `"like"` case to `apply_filter_op/5` in ash_adapter.ex
- [ ] 3.2 Add `"not_like"` case
- [ ] 3.3 Use Ash `ilike` filter for case-insensitive substring matching
- [ ] 3.4 Test query `in:devices ip:%172.16.80%` returns matching devices
- [ ] 3.5 Test query `in:devices hostname:%faker%` returns matching devices

## 4. Fix Array Field Handling

- [ ] 4.1 Add `@array_fields` MapSet with known array fields
- [ ] 4.2 Route array field filters to `in`/`contains_any` operator
- [ ] 4.3 Test query `in:devices discovery_sources:(sweep)` works
- [ ] 4.4 Verify no "text[] ~~ unknown" error for array queries

## 5. Remove Stale Tenant Code

- [ ] 5.1 Review `web-ng/lib/serviceradar_web_ng/ash_scope.ex` for tenant references
- [ ] 5.2 Remove unused tenant extraction code
- [ ] 5.3 Check Ash resources for leftover multitenancy config
- [ ] 5.4 Remove TenantRequired error handling workarounds

## 6. Testing

- [ ] 6.1 Add Ash adapter test for LIKE filter
- [ ] 6.2 Add Ash adapter test for array field filter
- [ ] 6.3 Manual test: Device page Available filter
- [ ] 6.4 Manual test: Device page Unavailable filter
- [ ] 6.5 Manual test: Device page Swept filter
- [ ] 6.6 Manual test: Search `ip:%172.16.80%`
- [ ] 6.7 Manual test: Search `hostname:%faker%`
- [ ] 6.8 Manual test: Time filter `time:last_24h`

## 7. Cleanup

- [ ] 7.1 Archive `fix-services-page-srql` proposal (outdated tenant references)
- [ ] 7.2 Close GitHub issues #2255, #2254, #2234
- [ ] 7.3 Update SRQL documentation if needed
