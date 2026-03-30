## Context
Datasvc exposes a gRPC object-upload path backed by JetStream object storage. The current implementation is safe from per-message memory blowups because lifecycle gRPC defaults bound frame size, but it still accepts arbitrarily long streams and creates the object-store bucket without `MaxBytes`.

## Goals / Non-Goals
- Goals:
  - fail closed when an uploaded object exceeds a configured cumulative byte limit
  - ensure the backing JetStream object bucket has an explicit storage ceiling
  - preserve normal streaming behavior for bounded uploads
- Non-Goals:
  - redesign datasvc authorization or object metadata semantics
  - introduce per-tenant quotas or multi-account behavior

## Decisions
- Decision: enforce a cumulative byte limit in `UploadObject` before bytes are committed indefinitely.
  - This keeps rejection close to the ingress boundary and avoids relying solely on JetStream backpressure.
- Decision: apply a JetStream `MaxBytes` cap to the object store.
  - This preserves service availability under repeated valid-but-large uploads and aligns object storage with the existing KV bucket capacity model.
- Decision: keep the hardening within datasvc rather than pushing limits to callers.
  - Datasvc is the enforcement point for storage safety; callers should not need to guess safe limits.

## Risks / Trade-offs
- Large legitimate uploads may now be rejected if operator configuration is too small.
  - Mitigation: make the limit explicit and test the failure behavior.
- Existing deployments with already-created unbounded object buckets may require careful update behavior.
  - Mitigation: prefer idempotent initialization that uses the configured cap on creation and documents the expectation for existing buckets.

## Migration Plan
1. Add explicit config-backed object upload/storage bounds.
2. Enforce the cumulative upload limit in the streaming RPC.
3. Ensure new object-store initialization applies the configured storage cap.
4. Add focused tests for oversize rejection and bounded bucket creation.

## Open Questions
- Whether to reuse `BucketMaxBytes` for the object bucket or introduce a dedicated object-store cap should be settled during implementation based on the least disruptive config shape.
