## Context
- OIDC and SAML configuration are operator-managed and may reference external metadata.
- The current outbound validation logic resolves the host during policy validation, but `Req` performs its own later resolution.
- Refresh tokens are currently reusable until expiry.
- The current auth rate limiter and config cache use caller-side ETS read/modify/write flows that are vulnerable under load.

## Goals
- Prevent XXE and external entity resolution while parsing SAML metadata.
- Ensure metadata and JWKS fetches cannot be redirected to a different resolved destination after validation.
- Enforce single-use refresh tokens during exchange.
- Make auth rate limiting and auth config refresh robust under concurrency.

## Non-Goals
- Changing user-facing login UX beyond the security-required refresh-rotation behavior.
- Replacing Guardian or Samly.
- General-purpose HTTP hardening outside auth metadata fetches.

## Decisions
- Add a shared auth outbound fetch helper that performs validation, resolution, and the actual request in one controlled path.
- Fail closed on SAML metadata parsing errors or attempts to reference external entities.
- Revoke the used refresh token during successful token exchange before returning the new credentials.
- Move rate limiter mutation/check logic behind the GenServer so checks and writes are serialized per process rather than racing in callers.
- Move config refresh coordination behind the GenServer so only one refresh query runs for an expired entry while concurrent callers wait for the same result.

## Risks / Trade-offs
- Binding requests to resolved addresses is more complex than plain `Req.get`, and TLS hostname verification must still use the original hostname.
- Refresh token rotation changes auth semantics; any existing caller that expects refresh token reuse will need to use the newly returned token.
- Serializing rate limiting and cache refresh introduces some contention, but these paths are low-volume compared with the security and stability gains.

## Migration Plan
1. Implement the shared auth fetch helper and switch OIDC/SAML metadata and JWKS retrieval to it.
2. Harden SAML metadata parsing.
3. Rotate refresh tokens during exchange and update tests.
4. Make rate limiter and config cache operations single-flight/serialized.
5. Run focused auth tests and compile validation.
