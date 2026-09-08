## 1. Spec
- [ ] 1.1 Update `edge-architecture` requirements so hosted edge-agent ingress does not require SPIFFE or SPIRE
- [ ] 1.2 Clarify that internal platform SPIFFE support remains unchanged

## 2. Gateway Identity Path
- [ ] 2.1 Update `ComponentIdentityResolver` so hosted edge-agent identity works without a SPIFFE URI SAN
- [ ] 2.2 Update `AgentGatewayServer` so hosted edge-agent requests default `component_type` to `agent` when SPIFFE SANs are absent
- [ ] 2.3 Preserve compatibility with already-issued certificates that still include SPIFFE URI SANs

## 3. Certificate Issuance And Onboarding
- [ ] 3.1 Update gateway-issued agent certificate bundles so hosted edge-agent certificates do not require SPIFFE SANs
- [ ] 3.2 Update onboarding and package generation paths that assume SPIFFE-derived edge identity

## 4. Verification
- [ ] 4.1 Add tests for hosted agent certificates that omit SPIFFE SANs
- [ ] 4.2 Add compatibility tests for older certificates that still include SPIFFE SANs
- [ ] 4.3 Update docs covering hosted edge mTLS identity expectations
- [ ] 4.4 Run `openspec validate remove-agent-gateway-spiffe-dependency --strict`
