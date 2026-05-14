## Context
ServiceRadar currently has multiple ingestion producers that can create or update inventory: Armis sync, sweep results, mapper promotion, SNMP/interface ingestion, metric enrichment, and manual inventory actions. The device identity cache was introduced to reduce repeated CNPG lookups, but stale entries can survive device creation, merge, soft-delete, restore, IP changes, or test setup. When ingestion trusts stale cache entries, failures surface as duplicate active IP constraint errors, missing devices during mapper promotion, or silent attachment to the wrong device.

The scale problem is real: a single Armis source may return tens of thousands of devices across multiple queries, and sweep execution may generate thousands of results per batch. Validation must exercise the same streaming and routing path used in production, not only isolated unit tests.

## Goals
- Make CNPG/DIRE the authoritative identity source for all writes and reconciliation decisions.
- Keep cache usage only where stale data cannot corrupt inventory or where the caller explicitly falls back to fresh data before mutating.
- Define invalidation responsibilities at every mutation point that can change canonical identity or active IP mappings.
- Provide repeatable large-dataset tests using faker and `$srql-fixtures-db-tests` so production is no longer the first end-to-end test.
- Make failures diagnosable with metrics/logs that show page counts, device counts, cache hit/miss/stale counts, streamed chunks, and ingestion totals.

## Expected Outcomes
- Large Armis syncs can be verified against faker before release, including multiple configured queries, pagination, token refresh, streaming, gateway routing, and final inventory counts.
- Sweep result ingestion no longer fails or silently misattributes results because of stale cache entries.
- Mapper promotion decisions use loaded authoritative devices, reducing noisy warnings and avoiding promotion metadata tied to stale identity references.
- Identity lookup call sites become auditable: a reviewer can tell whether a path is read-only cache-eligible or must use fresh database state.
- Operators get enough progress information to distinguish "still syncing", "partial sync", "auth retry", "streamed but not ingested", and "completed".

## Non-Goals
- This proposal does not remove the identity cache outright unless the caller audit proves no safe high-value use remains.
- This proposal does not redesign DIRE merge semantics beyond cache correctness and ingestion validation.
- This proposal does not move all scheduling from agents to core; integration scheduling concerns should be handled by a separate scheduler proposal if needed.

## Importance Assessment
This work is important if identity cache reads can still influence writes, promotion, or suppression decisions. In that case, correctness depends on cache freshness that is not currently visible or comprehensively tested, and production will remain the only environment exercising the full path at realistic scale.

This work is less important if the audit proves risky cache usage has already been removed and remaining callers are read-only enrichment paths. In that case, the right outcome is a much smaller change: make cache use explicit, preserve or delete low-value cache code, and focus effort on the large ingestion release gate.

The proposal should therefore start with the caller audit. That audit is the go/no-go checkpoint for the rest of the work.

## Decisions

### Identity Cache Contract
The default lookup behavior for ingestion and mutation paths should be cache-bypassing. Cache use is allowed for read-only enrichment and UI/status reads where a stale answer cannot create, update, merge, promote, or suppress a device. Any mutation path that starts from cached identity must re-check CNPG before writing or must prove the cache was refreshed by the same transaction/action.

### Invalidation Ownership
Device identity mutation points must publish invalidation or update the cache synchronously after commit. This includes device create/update, active IP changes, soft-delete/restore, identifier assignment, merge/unmerge, alias confirmation, sweep provisional device creation, Armis ingestion updates, and mapper/SNMP identity enrichment.

### Production-Repro Validation
The release gate should run a real integration path:
- faker emits at least 50k Armis-like devices across multiple queries and pages
- agent fetches pages and streams chunks through the same gRPC endpoint used in production
- agent-gateway routes chunks to core
- core ingests into inventory and records source metadata
- sweep group targeting compiles from the ingested inventory
- sweep results create/update devices and evaluate mapper promotion

The test should intentionally seed stale identity-cache entries and confirm they do not influence write paths.

## Risks
- Bypassing cache in hot ingestion loops can increase CNPG load. The implementation should batch authoritative lookups and measure query counts before/after.
- Cache invalidation that runs before transaction commit can create false misses or stale refreshes. Invalidation should happen after successful commit or through a transaction-aware mechanism.
- Large validation tests can be expensive. They should be separated into focused unit tests, DB-backed integration tests, and an explicit release-gate command rather than running in every local test loop.
- Overbuilding cache invalidation could create more complexity than value if the cache is not needed for performance-critical paths.
- Changing lookup defaults can expose hidden query costs or timing assumptions during ingestion bursts.

## Risks of Not Doing This
- Stale identity mappings can continue to cause duplicate active IP insert failures, missing-device mapper promotion metadata, or wrong-device attribution.
- Large Armis regressions can remain invisible until a real customer-sized production sync runs.
- Operators may keep seeing partial sync behavior without enough progress diagnostics to identify whether the fault is authentication, pagination, streaming, gateway routing, or core ingestion.
- Engineering fixes may remain reactive because there is no shared correctness contract for ingestion identity lookups.
