# Change: Refactor identity cache and ingestion correctness validation

## Why
Recent Armis, sweep, mapper promotion, and identity-cache fixes exposed a design problem: ingestion paths can still depend on stale cache state, and the only reliable validation path has been production. We need a clear contract for where cached identity data is allowed, where authoritative CNPG lookups are required, and how large integration payloads are validated before release.

## What Changes
- Define the identity cache as an optimization with explicit freshness, invalidation, and caller eligibility rules.
- Require mutation and ingestion workflows to resolve device identity through authoritative database paths, or through a cache path that proves freshness within the same operation.
- Audit all identity lookup callers and classify them as cache-eligible read enrichment, cache-bypassing ingestion, or cache-updating ownership points.
- Add regression coverage for stale cache entries, duplicate active IPs, soft-deleted devices, mapper promotion metadata, and large paged integration syncs.
- Establish a production-repro validation harness that runs the Armis faker, agent streaming, agent-gateway routing, core ingestion, sweep ingestion, and mapper promotion paths against large datasets before release.
- Document rollout expectations so operators can validate this path without waiting on several production release cycles.

## Value and Tradeoff
- Expected gain: fewer production-only discoveries, fewer duplicate-device and stale-device failures, clearer ownership of identity correctness, and faster confidence when shipping Armis/sweep/mapper changes.
- Expected operational improvement: operators should be able to tell whether a large sync is still progressing, partially failed, retried auth, streamed data, and reached core ingestion.
- Expected engineering improvement: ingestion PRs get a concrete release gate instead of relying on isolated unit tests or manual production observation.
- Risk of doing nothing: stale cache paths remain latent defects, large sync regressions may continue to appear only after production rollout, and fixes will keep being reactive hotfixes.
- Risk of doing this work: it can add DB load, implementation complexity, and a longer validation path unless scope is kept focused and cache-bypassing lookups are batched.
- Decision point: if the caller audit shows cache use is narrow and low-risk, prefer deleting or disabling risky cache behavior over building a broad invalidation subsystem.

## Impact
- Affected specs: device-identity-reconciliation, sweep-jobs, sync-service-integrations, ingestion-routing
- Affected code: `elixir/serviceradar_core/lib/serviceradar/devices/device_lookup.ex`, `elixir/serviceradar_core/lib/serviceradar/devices/identity_cache.ex`, sweep result ingestion, mapper promotion, Armis sync runtime, agent streaming, agent-gateway/core ingestion routing, faker fixtures, DB-backed integration tests
- Operational impact: adds validation gates and observability for large Armis and sweep ingestion runs; does not require a schema change unless invalidation audit finds missing persisted version markers
