## 1. Implementation
- [x] 1.1 Validate OIDC authorization redirect targets before browser redirect.
- [x] 1.2 Validate SAML metadata-derived SSO redirect targets before browser redirect.
- [x] 1.3 Sanitize threat-intel feed URL logging so secrets do not leak.
- [x] 1.4 Add regression tests for rejected redirect targets and sanitized threat-intel logging.

## 2. Validation
- [ ] 2.1 Run targeted auth and observability test coverage.
- [x] 2.2 Run `openspec validate harden-auth-redirect-targets-and-observability-secret-handling --strict`.
