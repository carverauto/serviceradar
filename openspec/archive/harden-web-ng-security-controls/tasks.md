## 1. Implementation
- [x] 1.1 Replace markdown rendering pipeline with explicit HTML sanitization that strips/blocks dangerous URL schemes and unsafe tags before `raw/1` output.
- [x] 1.2 Add unit tests proving markdown payloads like `javascript:` links and inline event handlers are neutralized.
- [x] 1.3 Tighten CSP policy in router by removing default `'unsafe-inline'` allowances where feasible and documenting any narrowly scoped exceptions.
- [x] 1.4 Add CSP regression tests (header content assertions on browser responses).
- [x] 1.5 Refactor SAML ACS validation to fail closed when certificates/signatures are missing and to perform cryptographic signature verification (not structural checks only).
- [x] 1.6 Add assertion hardening checks (issuer, audience/recipient, replay window constraints) with negative tests.
- [x] 1.7 Introduce a shared outbound URL validator for identity/JWKS metadata fetches (scheme restrictions, local/private address denial, timeout/redirect policy).
- [x] 1.8 Wire outbound URL validation into OIDC discovery/JWKS fetch, SAML metadata fetch, gateway JWKS fetch, and auth-settings test endpoints.
- [x] 1.9 Add tests proving disallowed URLs (localhost/link-local/private ranges) are rejected.

## 2. Verification
- [x] 2.1 Run `cd elixir/web-ng && mix test` (or targeted security test files) and resolve failures.
- [x] 2.2 Run `cd elixir/web-ng && mix precommit`.
- [x] 2.3 Capture a short security verification note in the change (what was tested, what payloads were blocked).
