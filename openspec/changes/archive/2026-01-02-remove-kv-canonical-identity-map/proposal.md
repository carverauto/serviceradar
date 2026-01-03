# Change: Remove KV canonical identity map publisher and dead code

## Why
GitHub issue `#2152` proposes fixes to `BuildKeysFromRecord` so alias identity keys can be reconstructed and stale alias keys deleted from the KV-backed canonical identity map.

Current implementation no longer uses KV as the authoritative device registry/canonicalization store:
- Core explicitly disables the KV identity map **publisher** (to avoid write amplification).
- Canonical identity resolution is performed via CNPG-backed `IdentityEngine` + `DeviceRegistry`, with KV used only as an optional cache/hydration layer for limited lookups (e.g. sweep IP caching).

As a result, the code path referenced in `#2152` appears to be effectively dead in normal operation, and the proposed fix may be unnecessary. The repository still contains legacy KV canonical-map publishing and KV lookup scaffolding that increases maintenance burden and creates confusion about the current identity architecture.

## What Changes
- Remove the unused KV canonical identity map publisher from the registry (`pkg/registry/identity_publisher.go`) and associated tests.
- Remove or simplify identitymap helpers that only exist to support the removed publisher (e.g. record→key reconstruction and alias-key KV support that is no longer written/read).
- Remove dead KV canonical-map lookup scaffolding from sync integrations (Armis/NetBox) where canonical identity resolution is now handled centrally by core.
- Update documentation to reflect the CNPG-authoritative identity flow and the limited KV cache/hydration role (and remove references to the removed publisher behavior).

## Impact
- Affected specs: `device-identity-reconciliation`
- Affected code:
  - `pkg/registry/*` (remove identity publisher wiring and dead types)
  - `pkg/identitymap/*` (drop publisher-only helpers)
  - `pkg/sync/integrations/{armis,netbox}/*` (remove dead canonical KV lookup scaffolding)
  - `docs/docs/architecture.md` (update identity canonicalization narrative)
- Behavior change: none intended for normal operation (publisher is currently disabled); reduces confusion and removes legacy paths.
