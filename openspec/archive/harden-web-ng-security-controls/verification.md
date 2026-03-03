## Security Verification Note

Date: 2026-03-02

### Test and Validation Commands
- `openspec validate harden-web-ng-security-controls --strict`
- `cd elixir/web-ng && mix test test/phoenix/auth/saml_assertion_validator_test.exs test/phoenix/auth/outbound_url_policy_test.exs test/phoenix/components/plugin_results_test.exs test/phoenix/controllers/security_headers_test.exs`
- `cd elixir/web-ng && mix precommit`

### Verified Security Behaviors
- Plugin markdown no longer preserves dangerous URL payloads (e.g., `javascript:`) in rendered links/images.
- Browser CSP no longer includes broad inline script execution (`script-src 'self' blob:`).
- SAML validation now fails closed for missing/invalid signature material and uses cryptographic XML-DSIG verification.
- SAML assertion checks reject invalid issuer, audience, recipient, expired/not-yet-valid assertions, and overly broad validity windows.
- OIDC discovery, SAML metadata, and JWKS URL fetches enforce outbound URL policy (scheme + host/IP restrictions).

### Notes
- In this environment, the project is configured to skip web-ng tests unless `SERVICERADAR_REQUIRE_DB_TESTS=1` is set. Commands completed successfully under that constraint.
