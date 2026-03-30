# Change: Harden Bootstrap Scripts and Sensitive Endpoints

## Why
Several authenticated and bootstrap-related paths still trust unsafe input or fail open on authorization-sensitive behavior. The highest-risk issues are shell command injection in generated install scripts, implicit SSO account linking by email, missing defense-in-depth authorization on sensitive snapshot/data endpoints, missing password-reset throttling, and raw internal error leakage from bundle endpoints.

## What Changes
- Harden generated bootstrap/update shell scripts so operator-provided values are treated as literal data, not executable shell syntax.
- Require explicit authorization checks on topology snapshot and spatial sample endpoints instead of relying only on router placement or authentication.
- Remove implicit SSO linking of existing local users by email and require safer linking behavior.
- Add rate limiting to password reset requests.
- Redact internal bundle generation errors returned by edge and collector bundle endpoints.
- Harden the SAML ACS parsing path so it fails closed on external entities and unsafe XML resources.

## Impact
- Affected specs: `edge-onboarding`, `ash-authentication`, `ash-authorization`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/collector_controller.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/edge/collector_bundle_generator.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng/edge/bundle_generator.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/topology_snapshot_controller.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/spatial_controller.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/saml_controller.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/oidc_controller.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/auth_controller.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/api/edge_controller.ex`

## Notes
- The pasted review’s SAML RelayState open-redirect concern is not included here because `UserAuth.log_in_user/3` already sanitizes `return_to`.
- The pasted review’s camera-analysis-worker SSRF claim is not included here because the current validated code path stores those URLs but does not itself issue outbound requests to them.
