# Change: Harden Token Pipelines and Federated Assertion Validation

## Why
Several auth and federation edge cases still fail open: the API pipeline currently accepts any signed JWT type, the auth rate limiter keeps unbounded timestamp history per key, SAML assertions do not require target constraints to be present when configured, and OIDC ID token verification/provisioning still allows missing nonce and required identity claims in some paths.

## What Changes
- Restrict API JWT acceptance to `access` and `api` token types and reject `refresh` tokens outside the refresh pipeline.
- Bound auth rate-limiter state to the active sliding window on every write.
- Require SAML audience and recipient values to be present and match configured SP expectations.
- Make OIDC ID token verification fail closed on missing nonce and missing required identity claims.

## Impact
- Affected specs: `ash-authentication`, `edge-architecture`
- Affected code: `elixir/web-ng/lib/serviceradar_web_ng_web/auth/pipeline.ex`, `guardian.ex`, `rate_limiter.ex`, `saml_assertion_validator.ex`, `oidc_client.ex`, controller/tests
