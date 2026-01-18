# Change: Fix SRQL Query Engine

## Why

The SRQL query engine has multiple critical bugs preventing basic search functionality:

1. **Quick filters missing entity token**: Device page quick filters (Available, Unavailable, Swept) generate queries like `discovery_sources:sweep` without the required `in:devices` prefix, causing "queries must include an in:<entity> token" error.

2. **LIKE queries not working**: Wildcard queries like `ip:%172.16.80%` and `hostname:%faker%` return no results even when matching data exists. The Ash adapter maps `like` to `contains` but doesn't handle SQL LIKE semantics with wildcards.

3. **Array field LIKE operator error**: Querying `discovery_sources` with patterns causes "operator does not exist: text[] ~~ unknown" because PostgreSQL can't use LIKE on arrays. The Ash adapter doesn't route array fields through proper array operators.

4. **TimeFilterSpec serialization failure**: The Rust NIF fails to serialize `TimeFilterSpec::RelativeHours` and `RelativeDays` variants, causing queries with time filters like `time:last_1h` to fail.

5. **Stale tenant code**: Old multitenancy code references remain that should be removed since tenant isolation has been removed from ServiceRadar.

## What Changes

### Fix 1: Device Quick Filters (UI)
- Update quick filter links in `device_live/index.ex` to include `in:devices` prefix
- Change `discovery_sources:sweep` to `in:devices discovery_sources:(sweep)`
- Change `is_available:true/false` to `in:devices is_available:true/false`

### Fix 2: LIKE Operator Support (Ash Adapter)
- Add `like` operator support to `apply_filter_op/5` in ash_adapter.ex
- Use Ash's `contains` filter but strip `%` wildcards and use case-insensitive substring matching
- For full LIKE semantics with start/end anchors, add proper pattern matching

### Fix 3: Array Field Handling (Ash Adapter)
- Detect array fields like `discovery_sources` and route through `in` operator
- Convert scalar values to single-element lists for array containment checks
- Remove LIKE attempts on array fields

### Fix 4: TimeFilterSpec Serialization (Rust)
- Fix serde serialization for newtype variants in `rust/srql/src/time.rs`
- Ensure adjacently-tagged enums serialize correctly to JSON

### Fix 5: Remove Tenant Code (Cleanup)
- Remove `TenantRequired` references and stale multitenancy code
- Archive the outdated `fix-services-page-srql` change proposal
- Clean up any tenant-related Ash resource configurations

## Impact

- **Affected specs**: `srql`
- **Affected code**:
  - `web-ng/lib/serviceradar_web_ng_web/live/device_live/index.ex` - Quick filters
  - `web-ng/lib/serviceradar_web_ng/srql/ash_adapter.ex` - LIKE and array handling
  - `rust/srql/src/time.rs` - TimeFilterSpec serialization
  - `web-ng/lib/serviceradar_web_ng/ash_scope.ex` - Tenant code removal

## GitHub Issues

- Fixes #2255 (discovery_sources LIKE on array)
- Fixes #2254 (search filters broken)
- Fixes #2234 (SRQL broken - TimeFilterSpec, TenantRequired)
