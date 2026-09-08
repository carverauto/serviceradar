## Context
ServiceRadar now supports signed agent release import from GitHub and Forgejo and supports token-gated onboarding bundle downloads for agents and collectors. Two weak points remain:
- outbound importer and mirroring fetches are not uniformly constrained to trusted destinations
- bundle download tokens still appear in URLs

The operator has confirmed that the only supported Forgejo host is `code.carverauto.dev`. That removes any need for dynamic Forgejo host selection and lets the system fail closed.

## Goals / Non-Goals
- Goals:
- Allow GitHub and `code.carverauto.dev` release imports while blocking arbitrary repo hosts.
- Ensure importer and mirror HTTP clients cannot reach loopback/private destinations or downgrade to HTTP.
- Prevent download-token disclosure through query strings.
- Preserve simple copy-paste install flows for operators and developers.
- Non-Goals:
- Adding generic support for arbitrary Forgejo instances.
- Replacing signed manifest verification or gateway-served artifact delivery.

## Decisions
- Decision: Pin Forgejo imports to `https://code.carverauto.dev`.
  - Alternatives considered: allow arbitrary Forgejo hosts with policy allowlists. Rejected because the deployment has a single trusted host and hardcoding removes a whole SSRF class.
- Decision: Use a shared outbound URL policy for release import and mirroring.
  - Alternatives considered: ad hoc validation per caller. Rejected because auth/JWKS fetches already use a central policy shape and importer/mirror should follow the same pattern.
- Decision: Move bundle downloads from `GET ?token=` to token delivery in request headers or POST body.
  - Alternatives considered: keep GET for convenience. Rejected because URL-based bearer material leaks too easily in logs, shells, and proxies.
- Decision: Only attach provider auth headers to trusted provider-owned hosts.
  - Alternatives considered: attach auth headers to any asset URL returned by the provider API. Rejected because it can leak tokens to attacker-controlled hosts.

## Risks / Trade-offs
- Existing automation that depends on `GET /bundle?token=...` will break and must switch to the new POST/header form.
  - Mitigation: update generated install commands and docs in the same change.
- Some existing signed manifests may reference hosts that will now be blocked by the stricter mirroring policy.
  - Mitigation: document the allowed release-source hosts and require internal mirroring to use approved HTTPS hosts only.

## Migration Plan
1. Add the spec deltas and implementation.
2. Switch generated install commands to the new bundle download method.
3. Reject old query-string bundle access.
4. Redeploy `web-ng` and `core`.
5. Re-test GitHub import, Forgejo import, and onboarding bundle flows.

## Open Questions
- None. Forgejo host allowlisting is explicitly fixed to `code.carverauto.dev`.
