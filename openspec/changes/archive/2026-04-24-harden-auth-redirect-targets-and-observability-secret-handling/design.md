## Context
ServiceRadar already validates some identity-provider metadata fetches and some outbound artifact/feed fetches, but the browser-redirect targets derived from identity metadata still are not consistently validated. On the observability side, outbound feed validation is now in place, but secret-bearing threat-intel URLs can still leak through routine logging.

## Goals / Non-Goals
- Goals:
  - Prevent compromised OIDC or SAML metadata from redirecting users to untrusted login endpoints.
  - Prevent observability workflows from leaking tokenized threat-intel feed URLs into logs or wider telemetry surfaces.
  - Keep current operator workflows intact for valid providers and feeds.
- Non-Goals:
  - Replace OIDC or SAML provider configuration models.
  - Redesign the threat-intel settings UI.

## Decisions
- Decision: validate both OIDC `authorization_endpoint` and SAML metadata-derived SSO URL before redirecting.
  - Rationale: browser redirects are still trust boundaries, even when the redirect target comes from a previously validated metadata document.
- Decision: treat threat-intel feed URLs as sensitive when they may carry secrets.
  - Rationale: operator-configured feeds routinely end up in logs unless explicitly redacted.

## Risks / Trade-offs
- Some misconfigured IdP metadata that previously worked may now fail closed.
  - Mitigation: return explicit configuration/auth failure instead of redirecting unsafely.
- Reduced URL logging may remove some operator debugging detail.
  - Mitigation: keep non-sensitive host/path context while redacting query/userinfo.

## Migration Plan
1. Add spec deltas for auth redirect validation and observability secret-safe handling.
2. Implement OIDC and SAML redirect target validation.
3. Sanitize observability secret-bearing URL handling and logging.
4. Add focused regression tests and update task state.
