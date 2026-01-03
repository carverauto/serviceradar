# Design Notes: Removing KV from identity paths

## Principle
CNPG is the source of truth for identity resolution and canonicalization. KV should not participate in identity correctness or be required for identity hot paths.

## Expected Result
- Identity lookups remain correct when datasvc/NATS KV is unavailable.
- No new `device_canonical_map/*` keys are created in the KV bucket during normal operation.
- Any remaining identity KV entries in existing environments are treated as legacy cache artifacts.

## Risks / Mitigations
- **Increased DB load on cold start**: mitigate via registry hydration on startup and in-memory cache TTL tuning.
- **Operational confusion**: docs explicitly state KV is not used for identity.
