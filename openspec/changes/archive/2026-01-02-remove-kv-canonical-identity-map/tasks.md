## 1. Confirm Current Runtime Behavior
- [x] 1.1 Trace core startup to confirm the KV identity map publisher is not wired into `DeviceRegistry`
- [x] 1.2 Enumerate remaining KV reads/writes related to identity and classify them (cache-only vs authoritative)
- [x] 1.3 Confirm no Helm/chart or runtime config path re-enables the removed publisher

## 2. Remove Registry KV Identity Publisher
- [x] 2.1 Delete `pkg/registry/identity_publisher.go` and tests that only cover publisher behavior
- [x] 2.2 Remove `DeviceRegistry.identityPublisher` field and `publishIdentityMap` call sites
- [x] 2.3 Ensure registry construction no longer exposes `WithIdentityPublisher`

## 3. Trim Identity Map Helpers
- [x] 3.1 Remove `BuildKeysFromRecord` if no longer referenced after publisher removal
- [x] 3.2 Remove alias-related KV identity key derivation if it is no longer written/read anywhere
- [x] 3.3 Ensure remaining identitymap utilities cover only the supported identity key kinds used by core (lookups/hydration/backfill)

## 4. Remove Dead Canonical KV Lookup Code in Sync Integrations
- [x] 4.1 Remove `prefetchCanonicalEntries` no-op stubs and any unreachable “direct KV lookup” fallback branches
- [x] 4.2 Remove unused key-ordering/canonical-record resolution helpers if no longer needed
- [x] 4.3 Keep KV usage that is still required for sync workflows (e.g., sweep config writes) intact

## 5. Update Documentation
- [x] 5.1 Update `docs/docs/architecture.md` to reflect CNPG-authoritative canonicalization and clarify KV’s cache-only identity role
- [x] 5.2 Remove stale rollout/metrics guidance that assumes the registry publishes canonical map keys to KV

## 6. Validation
- [x] 6.1 Run `go test ./...` (or the closest repo-standard subset) and fix only failures caused by this change
- [x] 6.2 Run `openspec validate remove-kv-canonical-identity-map --strict`
