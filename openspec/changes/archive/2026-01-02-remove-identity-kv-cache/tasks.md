## 1. Confirm Current Behavior (Demo + Code)
- [ ] 1.1 Capture current demo KV identity key counts by prefix and kind (`device_canonical_map/ip/*`, `device_canonical_map/partition-ip/*`)
- [ ] 1.2 Identify all runtime code paths that read/write `device_canonical_map/*` (lookup + hydration)
- [ ] 1.3 Confirm no other services rely on identity KV keys (only core)
- [ ] 1.4 Explain key cardinality (e.g., `2 * unique_ips` in TTL window) and validate against CNPG device/IP counts in demo

## 2. Remove Identity KV from Core Lookups
- [ ] 2.1 Update `GetCanonicalDevice` to skip KV and resolve via CNPG-backed paths only
- [ ] 2.2 Remove identity KV hydration (`hydrateIdentityKV`) or make it unreachable
- [ ] 2.3 Ensure OTEL lookup metrics still make sense without KV (`resolved_via` labels)

## 3. Remove Identity KV from Sweep Canonicalization
- [ ] 3.1 Remove KV read step in sweep canonicalization (`fetchCanonicalSnapshotsFromKV`)
- [ ] 3.2 Remove KV hydration for sweep snapshots (`persistIdentityForSnapshot`)
- [ ] 3.3 Ensure fallback order remains correct and efficient (in-memory cache → registry → CNPG)

## 4. Cleanup / Tooling
- [ ] 4.1 Evaluate `cmd/tools/kv-sweep` usage and either deprecate identity modes or remove them
- [ ] 4.2 Add a short runbook note for optional manual cleanup of legacy `device_canonical_map/*` keys (if retained)

## 5. Docs + Validation
- [ ] 5.1 Update `docs/docs/architecture.md` to remove KV identity cache assumptions
- [ ] 5.2 Run `go test ./...` and `openspec validate remove-identity-kv-cache --strict`
