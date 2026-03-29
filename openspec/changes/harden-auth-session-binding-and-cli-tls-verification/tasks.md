## 1. Implementation
- [x] 1.1 Make OIDC callback state and nonce validation fail closed when the stored session values are missing.
- [x] 1.2 Make SAML callback CSRF validation fail closed when the stored session value is missing.
- [x] 1.3 Generate password reset email links from the configured canonical endpoint URL.
- [x] 1.4 Remove `tls-skip-verify` support from the affected CLI bootstrap/admin commands and shared helpers.

## 2. Verification
- [x] 2.1 Add or update focused `web-ng` controller tests for missing-session OIDC/SAML callback rejection and canonical reset URL generation.
- [x] 2.2 Add or update focused Go CLI tests for removed TLS-skip behavior and default verified HTTPS transport.
- [ ] 2.3 Run the targeted auth and CLI test suites.
