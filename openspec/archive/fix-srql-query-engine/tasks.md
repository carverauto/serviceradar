# Tasks: Fix SRQL Query Engine

## 1. Fix TimeFilterSpec Serialization (Rust)

- [x] 1.1 Review current serde attributes in `rust/srql/src/time.rs`
- [x] 1.2 Verify serialization works (tests pass, NIF returns correct JSON)
- [x] 1.3 TimeFilterSpec already serializes correctly - no changes needed

## 2. Fix Quick Filter URLs (UI)

- [x] 2.1 Update Available filter in `device_live/index.ex` to `in:devices is_available:true`
- [x] 2.2 Update Unavailable filter to `in:devices is_available:false`
- [x] 2.3 Update Swept filter to `in:devices discovery_sources:(sweep)`
- [ ] 2.4 Test all quick filters work from UI

## 3. Add LIKE Operator to Ash Adapter

- [x] 3.1 Add `"like"` case to `apply_scalar_filter/4` in ash_adapter.ex
- [x] 3.2 Add `"not_like"` case
- [x] 3.3 Use Ash `contains` filter for substring matching
- [ ] 3.4 Test query `in:devices ip:%172.16.80%` returns matching devices
- [ ] 3.5 Test query `in:devices hostname:%faker%` returns matching devices

## 4. Fix Array Field Handling

- [x] 4.1 Add `array_field?/2` helper that introspects Ash resources dynamically
- [x] 4.2 Route array field filters to `has_any` operator
- [x] 4.3 Pass resource through filter chain for introspection
- [ ] 4.4 Test query `in:devices discovery_sources:(sweep)` works
- [ ] 4.5 Verify no "text[] ~~ unknown" error for array queries

## 5. Remove Stale Tenant Code

- [x] 5.1 Review `web-ng/lib/serviceradar_web_ng/ash_scope.ex` - clean (returns :error for tenant)
- [x] 5.2 Archive outdated `fix-services-page-srql` proposal
- [x] 5.3 No Ash resources have leftover multitenancy config

## 6. Testing

- [ ] 6.1 Manual test: Device page Available filter
- [ ] 6.2 Manual test: Device page Unavailable filter
- [ ] 6.3 Manual test: Device page Swept filter
- [ ] 6.4 Manual test: Search `ip:%172.16.80%`
- [ ] 6.5 Manual test: Search `hostname:%faker%`
- [ ] 6.6 Manual test: Time filter `time:last_24h`

## 7. Cleanup

- [x] 7.1 Archive `fix-services-page-srql` proposal (outdated tenant references)
- [ ] 7.2 Close GitHub issues #2255, #2254, #2234
