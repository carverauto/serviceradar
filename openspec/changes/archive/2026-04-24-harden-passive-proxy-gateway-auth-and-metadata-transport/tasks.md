## 1. Implementation
- [x] 1.1 Make passive proxy gateway auth fail closed when no JWT verification material is configured.
- [x] 1.2 Remove insecure HTTP auth metadata/JWKS URL support from the shared outbound auth URL policy.

## 2. Verification
- [x] 2.1 Add focused `web-ng` tests for unsigned passive proxy token rejection and insecure metadata URL rejection.
- [ ] 2.2 Run the targeted auth test/compile path and validate the OpenSpec change.
