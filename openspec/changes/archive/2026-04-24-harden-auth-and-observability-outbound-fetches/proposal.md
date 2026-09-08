# Change: Harden auth and observability outbound fetches

## Why
Recent security review found two remaining server-side outbound trust gaps. The OIDC callback flow validates discovery and JWKS URLs but does not validate the discovered token endpoint before posting the authorization code and client secret, and observability feed refresh workers still fetch configured URLs without a fail-closed outbound policy.

## What Changes
- Require OIDC token exchange to validate the discovered `token_endpoint` through the same outbound URL policy already used for discovery and JWKS fetches.
- Add a core-side outbound fetch policy for observability feed and dataset refresh workers so they reject invalid, non-HTTPS, and private/internal destinations before any network call.
- Constrain observability feed refreshes to documented remote sources and fail closed with observable errors when a configured URL is disallowed.
- Add regression coverage for rejected OIDC token endpoints and rejected observability feed URLs.

## Impact
- Affected specs: `ash-authentication`, `observability-signals`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/auth/oidc_client.ex`
  - `elixir/serviceradar_core/lib/serviceradar/observability/netflow_provider_dataset_refresh_worker.ex`
  - `elixir/serviceradar_core/lib/serviceradar/observability/netflow_oui_dataset_refresh_worker.ex`
  - `elixir/serviceradar_core/lib/serviceradar/observability/threat_intel_feed_refresh_worker.ex`
