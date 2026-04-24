## 1. Implementation
- [x] 1.1 Add OIDC token-endpoint outbound validation before token exchange in `web-ng`.
- [x] 1.2 Add a fail-closed outbound fetch policy for observability dataset and threat-intel refresh workers in `serviceradar_core`.
- [x] 1.3 Add regression tests for rejected OIDC token endpoints and rejected observability feed URLs.

## 2. Validation
- [ ] 2.1 Run targeted auth and observability test coverage.
- [x] 2.2 Run `openspec validate harden-auth-and-observability-outbound-fetches --strict`.
