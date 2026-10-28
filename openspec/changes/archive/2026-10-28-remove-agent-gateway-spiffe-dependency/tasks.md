## 1. Spec
- [x] 1.1 Update `edge-architecture` requirements so hosted edge-agent ingress does not require SPIFFE or SPIRE
- [x] 1.2 Clarify that internal platform SPIFFE support remains unchanged

## 2. Gateway Identity Path
- [x] 2.1 Update `ComponentIdentityResolver` so hosted edge-agent identity works without a SPIFFE URI SAN
- [x] 2.2 Update `AgentGatewayServer` so hosted edge-agent requests default `component_type` to `agent` when SPIFFE SANs are absent
- [x] 2.3 Preserve compatibility with already-issued certificates that still include SPIFFE URI SANs

## 3. Certificate Issuance And Onboarding
- [x] 3.1 Update gateway-issued agent certificate bundles so hosted edge-agent certificates do not require SPIFFE SANs
- [x] 3.2 Update onboarding and package generation paths that assume SPIFFE-derived edge identity

## 4. Verification
- [x] 4.1 Add tests for hosted agent certificates that omit SPIFFE SANs
- [x] 4.2 Add compatibility tests for older certificates that still include SPIFFE SANs
- [x] 4.3 Update docs covering hosted edge mTLS identity expectations
- [x] 4.4 Run `openspec validate remove-agent-gateway-spiffe-dependency --strict`
