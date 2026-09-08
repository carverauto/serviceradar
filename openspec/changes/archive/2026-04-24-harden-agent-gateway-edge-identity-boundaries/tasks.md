## 1. Gateway Listener Hardening
- [x] 1.1 Remove or fail closed on plaintext edge listener startup when gateway mTLS certs are unavailable.
- [x] 1.2 Add regression coverage proving the edge-facing gRPC and artifact listeners do not start in insecure mode.

## 2. Camera Relay Ownership Binding
- [x] 2.1 Require relay session heartbeat, upload, and close operations to match the authenticated session owner `agent_id`.
- [x] 2.2 Add focused tests for cross-agent relay mutation rejection and valid same-agent mutation success.

## 3. Certificate Issuance Tempfile Hardening
- [x] 3.1 Replace predictable certificate staging paths with secure exclusive temp directories/files.
- [x] 3.2 Add focused coverage for secure temp bundle creation and cleanup.

## 4. Verification
- [x] 4.1 Run focused `serviceradar_agent_gateway` tests for listener hardening, relay ownership binding, and cert issuance.
- [x] 4.2 Run `openspec validate harden-agent-gateway-edge-identity-boundaries --strict`.
