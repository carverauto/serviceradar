## 0. Schema (Clean Slate - Consolidate Migrations)

- [x] 0.1 Consolidate all 19 migrations in `pkg/db/cnpg/migrations/` into single idempotent schema file
- [x] 0.2 Remove `idx_unified_devices_ip_unique_active` constraint from consolidated schema
- [x] 0.3 Add `device_identifiers` table with unique constraint on (identifier_type, identifier_value, partition)
- [x] 0.4 No `_deleted`, no `_merged_into` handling in schema - clean columns only
- [x] 0.5 Schema must be idempotent (use `CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`, etc.)
- [x] 0.6 Delete all the old incremental migration files after consolidation

## 1. Consolidate Identity Resolution

- [x] 1.1 Create `pkg/registry/identity_engine.go` with unified `IdentityEngine` struct
- [x] 1.2 Implement strong identifier extraction: armis_device_id > integration_id > netbox_device_id > mac
- [x] 1.3 Implement deterministic sr: UUID generation from strong identifiers (hash-based, partition-scoped)
- [x] 1.4 On device insert: also insert into `device_identifiers` (DB enforces uniqueness)
- [x] 1.5 Delete `DeviceIdentityResolver`, `identityResolver`, `cnpgIdentityResolver`
- [x] 1.6 Delete `canonical_helpers.go`
- [x] 1.7 Update `DeviceRegistry` to use single IdentityEngine

## 2. Simplify Device Updates

- [x] 2.1 Rewrite `ProcessBatchDeviceUpdates()` - just UPSERT, no deduplication logic
- [x] 2.2 Delete `deduplicateBatch()`
- [x] 2.3 Delete `resolveIPConflictsWithDB()` and related helpers
- [x] 2.4 Delete all tombstone creation code
- [x] 2.5 Delete all `_deleted` / `_merged_into` handling in ProcessBatchDeviceUpdates
- [x] 2.6 Delete `filterObsoleteUpdates()` and deletion timestamp helpers
- [x] 2.7 IP changes just update the column - that's it

## 3. Simplify Queries

- [x] 3.1 Remove `_merged_into` filter from `unifiedDevicesSelection`
- [x] 3.2 Remove `_deleted` filter from `unifiedDevicesSelection`
- [x] 3.3 Remove `isCanonicalUnifiedDevice()` function (deleted with canonical_helpers.go)
- [x] 3.4 For explicit user deletion: hard DELETE + audit log to `device_updates`
- [x] 3.5 Delete `normalizeDeletionMetadata()` function and tests

## 4. Fix Registry/CNPG Consistency

- [x] 4.1 Add `SyncRegistryFromCNPG()` to hydrate in-memory registry from database
      - Query all devices from unified_devices table
      - Update in-memory deviceCache map
      - Should be callable on-demand and periodically
      - Implemented in `pkg/registry/registry_sync.go`
- [x] 4.2 Call sync on core startup and periodically (default 5m)
      - Add to registry initialization
      - `StartPeriodicSync()` method with configurable interval
      - `WithSyncInterval()` option for DeviceRegistry
- [x] 4.3 Add `registry_device_count` gauge metric
      - OpenTelemetry gauge showing len(r.devices)
      - Implemented in `pkg/registry/registry_sync_metrics.go`
- [x] 4.4 Add `registry_cnpg_drift` gauge metric
      - Compare registry count vs CNPG COUNT(*)
      - Metrics: `registry_cnpg_drift` (absolute) and `registry_cnpg_drift_percent`
      - `GetRegistrySyncMetrics()` helper for external access/alerting

## 5. E2E Cardinality Test

- [ ] 5.1 Add test: `COUNT(unified_devices) >= 50000`
- [ ] 5.2 Add test: `COUNT(DISTINCT armis_device_id) = COUNT(*)` (no duplicates)
- [ ] 5.3 Add to CI pipeline as required check

## 6. Test Updates

- [x] 6.1 Delete obsolete test files (registry_dedupe_test.go, ip_churn_test.go, reanimation_test.go)
- [x] 6.2 Delete obsolete tests for lookupCanonicalFromMaps, filterObsoleteUpdates, tombstone chain resolution
- [x] 6.3 Update remaining tests to mock `BatchGetDeviceIDsByIdentifier` for IdentityEngine calls
      - Fixed 3 tests: TestProcessBatchDeviceUpdates_MergesSweepIntoCanonicalDevice,
        TestReconcileSightingsMergesSweepSightingsByIP, TestReconcileSightingsPromotesEligibleSightings
      - Key fix: Don't use allowCanonicalizationQueries() when you need specific ExecuteQuery behavior
      - Key fix: ExecuteQuery DoAndReturn must include variadic param: `func(_, query string, _ ...interface{})`
- [x] 6.4 Update `canon_simulation_test.go` with correct mocks for new IdentityEngine flow
      - Renamed test to `TestDIREIdentityResolution`
      - Removed t.Skip(), test now runs
      - Tests 5 DIRE scenarios:
        1. Same strong ID always generates same sr:UUID (across IP changes)
        2. Different strong IDs generate different sr:UUIDs (even at same IP)
        3. Sweep-only devices at different IPs get deterministic sr:UUIDs
        4. MAC address acts as strong identifier
        5. Strong identifier priority: armis_device_id > mac
      - Uses `setupDIREMockDB()` to simulate device_identifiers table behavior

## 7. Verification

- [x] 7.1 `openspec validate fix-dire-engine --strict`
- [x] 7.2 `go test ./pkg/registry/...` passes
- [x] 7.3 `go test ./pkg/db/...` passes
- [x] 7.4 Deploy to demo, verify device counts
      - Built and pushed images: `sha-1c5559bc14e9ba0a3fb672ec2d1d8ca830e88b16`
      - Helm upgrade deployed successfully to demo namespace (revision 273)
      - Fixed BUILD.bazel: added `cnpg_identity_engine.go`, removed deleted test file
      - Fixed server.go: replaced `WithDeviceIdentityResolver`/`WithCNPGIdentityResolver` with `WithIdentityEngine`
      - Fixed stats_aggregator.go: deprecated `isTombstonedRecord()` - DIRE doesn't use tombstones
      - Cleaned database: removed `_merged_into` metadata from 10,039 legacy tombstoned records
      - CNPG verification results:
        - Total unified_devices: 50,004
        - Distinct armis_device_id: 50,000 (no duplicates!)
        - Devices without armis_device_id: 4 (sweep-only)
        - Stats aggregator now shows: `total_devices:50004, skipped_tombstoned_records:0`
- [ ] 7.5 24h soak test: device count stable at 50k through IP churn cycles
      - Monitor device count over 24 hours
      - Faker simulates IP churn (DHCP reassignment)
      - Count should remain stable at 50k (±small variance for timing)
      - Requires: Fresh database + running faker service for clean test

## Key Files Modified

- `pkg/registry/identity_engine.go` - NEW: unified IdentityEngine
- `pkg/registry/registry.go` - Simplified ProcessBatchDeviceUpdates, uses IdentityEngine
- `pkg/registry/registry_sync.go` - NEW: SyncRegistryFromCNPG() and periodic sync
- `pkg/registry/registry_sync_metrics.go` - NEW: OpenTelemetry metrics for registry sync/drift
- `pkg/db/cnpg_unified_devices.go` - Removed tombstone/deleted filters, added hard DELETE
- `pkg/db/cnpg_identity_engine.go` - NEW: DB methods for device_identifiers table
- `pkg/db/cnpg/migrations/00000000000001_schema.up.sql` - NEW: consolidated idempotent schema
- `pkg/db/BUILD.bazel` - Added cnpg_identity_engine.go, removed deleted test file
- `pkg/core/server.go` - Replaced old identity resolvers with WithIdentityEngine
- `pkg/core/stats_aggregator.go` - Deprecated isTombstonedRecord(), DIRE doesn't use tombstones

## Deleted Files

- `pkg/registry/device_identity.go`
- `pkg/registry/device_identity_test.go`
- `pkg/registry/identity_resolver.go`
- `pkg/registry/identity_resolver_test.go`
- `pkg/registry/identity_resolver_cnpg.go`
- `pkg/registry/identity_resolver_cnpg_test.go`
- `pkg/registry/canonical_helpers.go`
- `pkg/registry/registry_dedupe_test.go`
- `pkg/registry/ip_churn_test.go`
- `pkg/registry/reanimation_test.go`
- `pkg/db/cnpg_unified_devices_test.go`
- All old migration files (00000000000002 through 00000000000018)
