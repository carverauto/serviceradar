# Change: Harden Gateway Proxy Authentication (web-ng)

## Why
Gateway Proxy mode (`passive_proxy`) is intended to let an upstream gateway authenticate users and inject identity via JWT, but the current behavior can be misconfigured in ways that allow unintended access (for example, accepting unsigned/unverifiable tokens or allowing direct access without the gateway).

We want a secure, well-defined, and test-covered behavior for passive proxy deployments.

## What Changes
- Define and enforce required configuration for `passive_proxy` (JWKS URL or public key).
- Make passive proxy authentication work end-to-end for the Phoenix LiveView UI (session establishment after gateway verification).
- Ensure direct access to web-ng does not bypass the gateway when passive proxy mode is enabled (with an explicit, limited admin escape hatch).
- Add security-focused tests for the gateway auth plug and the request pipeline behavior.

## Impact
- Affected specs: `ash-authentication`
- Affected code:
  - `web-ng/lib/serviceradar_web_ng_web/plugs/gateway_auth.ex`
  - `web-ng/lib/serviceradar_web_ng_web/user_auth.ex`
  - `web-ng/lib/serviceradar_web_ng_web/router.ex`
- Deployment/ops:
  - Operators using Gateway Proxy mode must provide verifiable JWT configuration (JWKS or PEM) and claim mappings.
  - Documentation will be updated to match the hardened behavior.

