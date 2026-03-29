# Change: Harden Auth Metadata Fetching and Refresh Rotation

## Why
Several authentication security issues remain in the current `web-ng` auth stack: SAML metadata parsing still relies on ineffective `xmerl` options for XXE prevention, outbound metadata fetches validate hosts before issuing a separate HTTP request that can be rebound by DNS, refresh token exchange does not revoke the used refresh token, and the in-memory rate limiter/config cache both rely on racy caller-side ETS patterns under concurrency.

These are security hardening changes to authentication behavior and should be made explicitly and consistently.

## What Changes
- Replace the current SAML metadata parsing path with an XXE-safe parser configuration that disables external fetches.
- Introduce a shared authenticated outbound fetch path for OIDC/SAML metadata and JWKS retrieval that binds requests to the validated resolution result instead of validating and then performing a separate unconstrained fetch.
- Rotate refresh tokens on exchange by revoking the used refresh token before returning newly issued credentials.
- Make auth rate limiting atomic under concurrency so concurrent login bursts cannot bypass attempt counts.
- Make auth settings cache refresh single-flight so TTL expiry does not trigger a database stampede.

## Impact
- Affected specs: `ash-authentication`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/auth/saml_strategy.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/auth/oidc_client.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/auth/outbound_url_policy.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/auth/guardian.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/auth/rate_limiter.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/auth/config_cache.ex`
  - focused auth tests
