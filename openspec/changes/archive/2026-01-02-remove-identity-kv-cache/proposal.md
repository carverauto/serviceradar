# Change: Remove KV identity cache/hydration from core

## Why
We want KV to be used for configuration (and other non-identity workflows like edge onboarding), not for device identity canonicalization or caching.

Although the KV-backed identity map **publisher** has been removed/disabled, the core service still performs **KV identity caching/hydration**:
- The demo cluster’s `serviceradar-datasvc` KV bucket currently contains `100,000` `device_canonical_map/*` entries (50k `ip/*` + 50k `partition-ip/*`), showing the core is actively writing identity records into KV.
  - This is not “100k devices”; it is ~2 keys per device/IP (`ip/*` + `partition-ip/*`). With IP churn or multi-IP devices, the key count can exceed `2 * device_count` within the TTL window.
- This makes identity behavior harder to reason about (“are we using KV or not?”), and creates an implicit dependency on datasvc/NATS for identity hot paths.
  - At scale (e.g., 2M devices), even `2 * N` keys is millions of KV entries competing with config data in the same bucket.

This change removes KV from the identity path entirely so identity resolution is always CNPG + in-memory caches, while KV remains for configs/edge workflows.

## What Changes
- Core no longer reads KV for identity lookup or sweep canonicalization.
- Core no longer hydrates identity mappings into KV (`device_canonical_map/*`).
- `GetCanonicalDevice` continues to exist but becomes CNPG-only (no KV-first lookup, no KV hydration side effects).
- Documentation and operational guidance are updated to reflect that KV is not part of the identity path.

## Impact
- Affected specs: `device-identity-reconciliation`
- Affected code (expected):
  - `pkg/core/identity_lookup.go` (remove KV-first + hydration)
  - `pkg/core/result_processor.go` (remove KV identity cache reads/writes)
  - `pkg/core/server.go` (stop wiring KV client into identity paths)
  - `cmd/tools/kv-sweep` (deprecate or remove identity-specific behaviors, if appropriate)
- Performance/behavior: increased CNPG/in-memory reliance during cache misses; reduced datasvc/NATS dependency; removes identity KV growth.
- Migration: existing `device_canonical_map/*` keys become legacy/unused and can be cleaned up separately (optional).
