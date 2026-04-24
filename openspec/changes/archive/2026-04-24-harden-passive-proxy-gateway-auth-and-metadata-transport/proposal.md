# Change: Harden Passive Proxy Gateway Auth And Metadata Transport

## Why
Passive proxy authentication currently fails open when JWT signature verification is not configured, which allows unsigned gateway headers to establish user sessions. The shared auth metadata fetch policy also still permits an insecure HTTP downgrade behind a config flag, which weakens the OIDC/SAML trust chain.

## What Changes
- Require passive proxy gateway authentication to fail closed unless JWT signature verification is configured with either JWKS or a static public key.
- Remove support for insecure `http://` auth metadata and JWKS URLs from the shared outbound auth fetch policy.
- Add focused regression coverage for unsigned passive proxy tokens and insecure metadata URL rejection.

## Impact
- Affected specs: `ash-authentication`
- Affected code: `elixir/web-ng/lib/serviceradar_web_ng_web/plugs/gateway_auth.ex`, `elixir/web-ng/lib/serviceradar_web_ng_web/auth/outbound_url_policy.ex`, related auth tests and docs
