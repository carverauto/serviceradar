# Design Notes: KV canonical identity map cleanup

## Current State (Observed)
- Core initializes a KV client for features that still require it (edge onboarding, identity lookups), but explicitly states the KV identity map **publisher** is disabled.
- Registry canonicalization is CNPG-backed via `IdentityEngine` and persisted in `unified_devices` + `device_identifiers`.
- Core may still read/hydrate limited identity keys in KV as an optimization during sweep processing and `GetCanonicalDevice` requests, but this is cache-only and must degrade gracefully.
- Sync integrations include legacy code to resolve canonical identities via KV, but now intentionally avoid KV reads because canonical resolution happens centrally.

## Goal
Align the codebase and docs with the current architecture by removing the unused publisher and any unreachable KV canonical-map code paths, while keeping the KV features that are still active (edge onboarding, config/seeding, cache-only sweep hydration).

## Non-Goals
- Changing canonical identity rules or introducing new identity kinds.
- Removing datasvc/KV as a product dependency (KV is still required for configuration and edge onboarding).
- Migrating existing customer KV buckets in this change (if any exist, provide an operational note, not an automated migration).

## Compatibility / Migration Considerations
- If any environments still have canonical identity buckets from older versions, ensure they can be safely ignored or cleaned up with existing tooling (or document a manual cleanup path).
- Backfill paths that seed KV identity keys should be evaluated: either keep as explicitly “legacy tooling” or remove if no longer used.
