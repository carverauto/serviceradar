## Context
The NATS account-signing layer is supposed to preserve namespace/account isolation while allowing controlled provisioning of tenant or workload credentials. Today it signs arbitrary imports and permission overrides, and it defaults JetStream limits to `NoLimit`.

## Goals / Non-Goals
- Goals:
  - prevent signed accounts and user creds from escaping approved namespace/account scope
  - ensure new accounts have bounded JetStream quotas by default
  - keep datasvc as a thin transport layer while enforcing security-critical validation in the signing path
- Non-Goals:
  - redesign the higher-level tenant provisioning model
  - introduce multitenancy features into single-deployment platform code paths

## Decisions
- Decision: validate imports, exports, subject mappings, and custom user permissions against namespace/account scope before signing.
  - The signing layer is the last trusted point before authority becomes durable JWT state.
- Decision: finite JetStream quotas must be present on new accounts.
  - Namespace isolation without bounded resource limits still allows noisy-neighbor and storage exhaustion behavior.
- Decision: datasvc request handlers should reject out-of-scope requests early, but the account library should also enforce the invariant.
  - This provides defense in depth if another caller uses the package directly.

## Risks / Trade-offs
- Existing callers that relied on arbitrary custom subjects or unlimited JetStream quotas may now be rejected.
  - Mitigation: keep the allowlist tight and update tests/docs to make the accepted scope explicit.

## Migration Plan
1. Define the allowed namespace/account scope contract in OpenSpec.
2. Enforce scope validation in `go/pkg/nats/accounts`.
3. Reject invalid caller-supplied fields in datasvc request conversion/validation paths.
4. Install bounded JetStream defaults or require bounded limits.
5. Add focused tests for both authority narrowing and finite quotas.
