## 1. Proposal
- [ ] Confirm intended semantics for `passive_proxy`:
  - [ ] Whether gateway JWT is required on every request or only to establish a session
  - [ ] Whether session-only access is allowed without a gateway header
  - [ ] Whether to validate `iss`/`aud` by default (and how to surface warnings)
- [ ] Identify all routes that must bypass gateway enforcement (ex: `/users/log-in`, `/auth/local`, password reset)
- [ ] Run `openspec validate harden-gateway-proxy-auth --strict`

## 2. Implementation
- [ ] In `passive_proxy`, enforce that JWKS URL or PEM is configured before enabling
- [ ] Ensure gateway-authenticated users can use the LiveView UI (establish a session token after JWT verification)
- [ ] Prevent direct (non-gateway) access from authenticating in `passive_proxy` mode, except for the explicit admin path(s)
- [ ] Add unit/integration tests covering:
  - [ ] No JWT present (expected behavior)
  - [ ] Invalid signature / missing key material
  - [ ] Missing required claims (email/sub)
  - [ ] JIT provisioning creates viewer user by default
  - [ ] Admin local login path remains functional
- [ ] Update docs to match the final behavior

## 3. Verification
- [ ] `cd docs && npm run build`
- [ ] `cd web-ng && mix test` (or focused tests for auth plug + router)

