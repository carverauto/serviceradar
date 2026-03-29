## Context
- `serviceradar-agent-gateway` is the edge-facing trust boundary for agent gRPC, release artifact delivery, and camera relay traffic.
- The current gateway startup path still allows a plaintext override when edge certs are absent.
- Camera relay sessions record the owning `agent_id` at open time, but subsequent mutations are keyed only by `relay_session_id` and `media_ingest_id`.
- Gateway-issued certificate bundles are staged under predictable global temp paths while writing private keys.

## Goals / Non-Goals
- Goals:
  - Preserve mTLS as a mandatory edge trust boundary in production code paths.
  - Ensure relay session mutation rights stay bound to the authenticated edge identity that owns the session.
  - Ensure private-key staging during certificate issuance uses secure temp handling.
- Non-Goals:
  - Redesign the gateway CA or onboarding certificate format.
  - Change platform-internal ERTS transport.
  - Introduce new multitenancy behavior.

## Decisions
- Decision: Gateway startup will fail closed if edge-facing certs are unavailable.
  - Rationale: The edge gateway exists specifically to terminate authenticated mTLS. A plaintext fallback undermines the control-plane trust boundary and should not remain a runtime option.
- Decision: Relay session lookups will require `agent_id` ownership in addition to existing relay identifiers.
  - Rationale: `relay_session_id` and `media_ingest_id` are session references, not authority. Ownership must remain certificate-bound to the authenticated caller.
- Decision: Certificate issuance will use secure random exclusive temp directories/files.
  - Rationale: Private keys should not be written into predictable global temp paths, even on internal hosts.

## Risks / Trade-offs
- Local development that relied on insecure gateway startup will need real certs or explicit test-only injection/mocks.
- Binding relay session mutations to `agent_id` may expose hidden client bugs where agents accidentally send mismatched IDs.

## Migration Plan
1. Update the gateway startup path to reject insecure listener fallback.
2. Update camera relay session tracker APIs to require owner `agent_id`.
3. Update camera relay server handlers and tests to enforce owner binding.
4. Replace predictable certificate temp paths with secure exclusive temp staging.
5. Re-run focused gateway tests and update the review baseline disposition.

## Open Questions
- None.
