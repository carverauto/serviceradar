## Context
Recent hardening moved several delivery flows from `GET ?token=...` to POST plus header/body tokens. Some handlers still read merged Phoenix request params, which means POST query-string tokens remain accepted. Edge bundle generation also reuses request host data when building bundle contents, which is not a trustworthy source for bootstrap URLs.

## Goals
- Eliminate URL-borne bearer token acceptance from token-gated POST delivery endpoints.
- Ensure onboarding bundles use a stable, operator-controlled base URL.

## Non-Goals
- Redesign the overall onboarding token model.
- Change authenticated admin APIs that mint short-lived download tokens.

## Decisions
### Token extraction
- Public and token-gated POST endpoints SHALL read tokens only from explicit headers or POST request bodies.
- Query-string values SHALL NOT be accepted as token sources on those endpoints.

### Bundle base URL
- Bundle generation SHALL use `EndpointConfig.base_url/0` or another explicit configured base URL source.
- Inbound request `Host` and scheme SHALL NOT influence generated install commands or config payloads.
