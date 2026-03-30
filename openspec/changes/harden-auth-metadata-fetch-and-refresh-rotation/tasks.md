## 1. Implementation
- [x] 1.1 Add a shared auth outbound fetch helper that binds the request to the validated resolution result and use it for OIDC discovery, token exchange, JWKS fetch, and SAML metadata fetch.
- [x] 1.2 Replace the current SAML metadata parser options with an XXE-safe parsing path that disables external entity fetching.
- [x] 1.3 Revoke used refresh tokens during refresh-token exchange and update callers/tests for rotated-token behavior.
- [x] 1.4 Make the auth rate limiter atomic under concurrency.
- [x] 1.5 Make auth config cache refresh single-flight under TTL expiry and invalidation.

## 2. Verification
- [x] 2.1 Add or update focused tests for SAML parsing hardening and outbound auth fetch behavior.
- [x] 2.2 Add or update focused tests for refresh-token rotation.
- [x] 2.3 Add or update concurrency-focused tests for the auth rate limiter and config cache behavior.
- [ ] 2.4 Run `mix compile` in `elixir/web-ng` and relevant focused `mix test` targets.
