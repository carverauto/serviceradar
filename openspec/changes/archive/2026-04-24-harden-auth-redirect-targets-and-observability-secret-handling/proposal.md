# Change: Harden auth redirect targets and observability secret handling

## Why
Security review found two remaining metadata-driven redirect gaps in OIDC and SAML login initiation, plus one observability secret-handling leak. OIDC still trusts the discovery document's authorization endpoint for browser redirects, SAML still trusts metadata-derived SSO URLs for browser redirects, and threat-intel refresh logging still emits full configured feed URLs that may contain credentials.

## What Changes
- Require OIDC login initiation to validate the discovered `authorization_endpoint` through the outbound URL policy before redirecting the browser.
- Require SAML login initiation to validate metadata-derived SingleSignOnService URLs through the outbound URL policy before redirecting the browser.
- Redact or avoid logging raw threat-intel feed URLs so tokenized feed URLs do not leak into logs.
- Add regression coverage for rejected auth redirect targets and sanitized threat-intel logging.

## Impact
- Affected specs: `ash-authentication`, `observability-signals`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/auth/oidc_client.ex`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/saml_controller.ex`
  - `elixir/serviceradar_core/lib/serviceradar/observability/threat_intel_feed_refresh_worker.ex`
