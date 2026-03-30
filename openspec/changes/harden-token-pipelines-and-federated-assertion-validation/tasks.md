## 1. Implementation
- [x] 1.1 Restrict API JWT verification to `access` and `api` token types.
- [x] 1.2 Bound auth rate-limiter state to the active window on each write.
- [x] 1.3 Require configured SAML audience and recipient values to be present and match.
- [x] 1.4 Require OIDC nonce and required identity claims before successful provisioning.

## 2. Verification
- [x] 2.1 Add or update focused tests for API pipeline token-type enforcement.
- [x] 2.2 Add or update focused tests for bounded rate-limiter state.
- [x] 2.3 Add or update focused tests for strict SAML audience/recipient validation.
- [x] 2.4 Add or update focused tests for OIDC nonce and required-claim validation.
- [ ] 2.5 Run `mix compile` in `elixir/web-ng` and the relevant focused `mix test` targets.
