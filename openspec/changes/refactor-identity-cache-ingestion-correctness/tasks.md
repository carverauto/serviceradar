## 1. Caller Audit
- [x] 1.1 Inventory every caller of `IdentityCache`, `DeviceLookup.batch_lookup_by_ip/2`, `DeviceLookup.get_canonical_device/2`, and cache-related options.
- [x] 1.2 Classify each caller as read-only cache-eligible, ingestion/mutation cache-bypassing, or cache owner/invalidation producer.
- [x] 1.3 Document the final caller table in code comments or developer docs close to `DeviceLookup`.

## 2. Identity Lookup Policy
- [x] 2.1 Make cache use explicit at call sites that are allowed to use it.
- [x] 2.2 Ensure ingestion and mutation paths use authoritative batched CNPG/DIRE lookups before creating, updating, promoting, or suppressing devices.
- [x] 2.3 Add guardrails or tests that fail when new ingestion callers rely on the cache by default.

## 3. Cache Freshness and Invalidation
- [x] 3.1 Add invalidation or refresh hooks for device create/update, active IP changes, soft-delete/restore, merge/unmerge, identifier assignment, and alias confirmation.
- [x] 3.2 Add invalidation or refresh hooks for sweep provisional creation, mapper promotion metadata, Armis ingestion updates, and SNMP/interface identity enrichment.
- [x] 3.3 Add metrics/log fields for identity cache hits, misses, stale rejects, invalidations, and authoritative fallback counts.

## 4. Sweep and Mapper Regression Coverage
- [x] 4.1 Add DB-backed tests that seed stale cache entries and verify sweep result ingestion creates or resolves the correct device.
- [x] 4.2 Add tests for duplicate active IP conflicts, soft-deleted devices, restored devices, and recently changed active IPs.
- [x] 4.3 Add mapper promotion tests that verify promotion metadata is persisted only for loaded authoritative devices.
- [x] 4.4 Verify sweep target compilation ignores integration-specific blacklist settings and only uses sweep group targeting inputs.

## 5. Armis and Large Ingestion Validation
- [x] 5.1 Extend the Armis faker scenario to serve multiple configured queries, token refreshes, paged results, partial failures, and at least 50k fake devices.
- [x] 5.2 Add an end-to-end harness that runs agent fetch, gRPC streaming, agent-gateway routing, core ingestion, and inventory assertions.
- [x] 5.3 Assert streamed device counts, chunk counts, final inventory counts, source metadata, and retry behavior.
- [x] 5.4 Ensure the harness can be run with `$srql-fixtures-db-tests` or an equivalent isolated CNPG database.

## 6. Release Gate and Operations
- [x] 6.1 Add a documented command sequence for the large ingestion validation path.
- [x] 6.2 Add release checklist items requiring DB-backed identity tests and the faker streaming harness before tagging releases that touch ingestion.
- [x] 6.3 Add operator-facing diagnostics for Armis run state, page progress, last error, token refresh count, and streamed/ingested device totals.
