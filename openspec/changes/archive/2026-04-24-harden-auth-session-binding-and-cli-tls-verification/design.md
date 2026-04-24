## Context
Recent hardening removed several outbound URL and token transport issues, but three related trust-boundary gaps remain:

- browser auth callbacks still treat missing session state as acceptable in some paths
- password reset emails still derive an absolute link from the inbound request host
- CLI bootstrap/admin commands still expose an operator toggle that disables TLS certificate verification

These are all fail-open behaviors in paths that should be fail-closed.

## Goals
- Require a stored session token for OIDC and SAML callback success.
- Ensure password reset emails use the configured canonical endpoint URL.
- Remove TLS verification bypass from CLI flows that contact the control plane over HTTPS.

## Non-Goals
- Changing the reset-token format or Guardian token semantics.
- Reworking camera/device/plugin operator-controlled insecure upstream settings.
- Changing external vendor integrations that require token-in-query-string behavior.

## Design
### Auth callback session binding
- OIDC callback validation must reject the request unless:
  - a stored session `oidc_state` exists
  - the callback `state` exists
  - they compare equal
  - a stored `oidc_nonce` exists and the ID token nonce matches it
- SAML callback validation must reject the request unless:
  - a stored session `saml_csrf_token` exists
  - the RelayState token exists
  - they compare equal

### Canonical reset URLs
- Password reset emails should build the absolute URL from `ServiceRadarWebNG.Web.EndpointConfig.base_url/0` plus the verified route path.
- This keeps email links independent of spoofed `Host` headers on the reset request.

### CLI TLS verification
- Remove `TLSSkipVerify` from the shared CLI config and all CLI flags/help text for the affected commands.
- Shared HTTP client helpers for those command paths should always use default TLS verification.
- The hardened scope includes control-plane bootstrap/admin flows, specifically:
  - edge package create/list/download/revoke style commands
  - NATS bootstrap/token/status commands
  - SPIRE join token commands

## Risks
- Removing CLI flags is a breaking UX change for any existing scripts that still pass `--tls-skip-verify`.
- Some tests may currently rely on sessionless callback behavior and need explicit session setup.
