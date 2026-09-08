## 1. Proposal
- [x] Confirm intended semantics for `passive_proxy`:
  - [x] Gateway JWT is required to establish the ServiceRadar browser session; subsequent LiveView navigation uses the normal session token.
  - [x] Session-only access is allowed only after a valid gateway JWT or local admin login has established the session.
  - [x] `iss`/`aud` validation remains optional but is enforced when configured; signature verification material is mandatory.
- [x] Identify all routes that must bypass gateway enforcement (`/auth/local`, `/auth/local/sign-in`; existing unauthenticated routes still use normal route guardrails)
- [x] Run `openspec validate harden-gateway-proxy-auth --strict`

## 2. Implementation
- [x] In `passive_proxy`, enforce that JWKS URL or PEM is configured before enabling
- [x] Ensure gateway-authenticated users can use the LiveView UI (establish a session token after JWT verification)
- [x] Prevent direct (non-gateway) access from authenticating in `passive_proxy` mode, except for the explicit admin path(s)
- [x] Add unit/integration tests covering:
  - [x] No JWT present (expected behavior)
  - [x] Invalid signature / missing key material
  - [x] Missing required claims (email/sub)
  - [x] JIT provisioning creates viewer user by default
  - [x] Admin local login path remains functional
- [x] Update docs to match the final behavior

## 3. Verification
- [x] `cd docs && npm run build`
- [x] `cd elixir/web-ng && mix test` (or focused tests for auth plug + router)
