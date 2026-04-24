# Change: Harden auth callback session binding and CLI TLS verification

## Why
The current auth and bootstrap surfaces still have a few fail-open security paths. OIDC and SAML callbacks can proceed without a valid stored session token, password reset emails build absolute links from the inbound request host, and several CLI bootstrap/admin flows still permit TLS certificate verification bypass.

## What Changes
- Make OIDC and SAML callback validation fail closed when the expected session-bound CSRF/state material is missing.
- Generate password reset links from the configured canonical endpoint URL instead of the inbound request host.
- Remove `tls-skip-verify` support from control-plane CLI bootstrap/admin flows that talk to HTTPS endpoints.

## Impact
- Affected specs: `ash-authentication`, `edge-architecture`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/oidc_controller.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/saml_controller.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/auth_controller.ex`
  - `go/pkg/cli/cli.go`
  - `go/pkg/cli/edge_onboarding.go`
  - `go/pkg/cli/nats_bootstrap.go`
  - `go/pkg/cli/spire.go`
