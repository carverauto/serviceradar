## 1. Implementation
- [x] 1.1 Harden collector and edge bundle/install script generation so embedded values are shell-literal safe.
- [x] 1.2 Add explicit authorization checks to topology snapshot and spatial sample controllers.
- [x] 1.3 Remove implicit email-based SSO account linking for existing local users and fail closed on unsafe linking conditions.
- [x] 1.4 Add rate limiting to password reset requests.
- [x] 1.5 Replace raw inspected bundle errors with client-safe error responses and server-side logging.
- [x] 1.6 Harden the SAML ACS XML parsing path against external entity resolution.

## 2. Verification
- [x] 2.1 Add or update focused tests for shell script escaping and generated command safety.
- [x] 2.2 Add or update focused tests for topology/spatial authorization behavior.
- [x] 2.3 Add or update focused tests for SSO linking restrictions and password reset throttling.
- [x] 2.4 Add or update focused tests for bundle error redaction and SAML ACS parsing hardening.
- [ ] 2.5 Run `mix compile` in `elixir/web-ng` and the relevant focused `mix test` targets.
