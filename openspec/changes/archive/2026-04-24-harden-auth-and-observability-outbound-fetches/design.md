## Context
ServiceRadar already has an outbound URL policy in `web-ng` for identity-provider discovery and JWKS fetches, and it has feed-driven background refresh workers in `serviceradar_core`. The remaining issue is inconsistency: one auth step still trusts an unvalidated discovered endpoint, and the core workers still fetch configured remote URLs without the same private-address and scheme guardrails now used in other hardened fetch paths.

## Goals / Non-Goals
- Goals:
  - Prevent OIDC discovery metadata from redirecting token exchange to untrusted endpoints.
  - Prevent observability feed refresh jobs from being used as arbitrary HTTPS fetchers into internal or private networks.
  - Preserve the current operator workflows for known public feeds while failing closed on unsafe URLs.
- Non-Goals:
  - Redesign the OIDC provider configuration model.
  - Add a generic outbound-policy framework for every future HTTP call in the repo.
  - Remove the current public observability feed sources.

## Decisions
- Decision: validate OIDC `token_endpoint` before token exchange.
  - Rationale: discovery and JWKS already go through `OutboundURLPolicy`; token exchange should use the same boundary.
- Decision: add a core-side outbound fetch policy for observability refresh workers.
  - Rationale: `serviceradar_core` cannot depend on the `web-ng` auth module, but it needs equivalent SSRF protections for operator-configured URLs.
- Decision: keep observability feed refreshes limited to HTTPS and non-private/non-loopback/non-link-local destinations.
  - Rationale: these workers fetch remote public reference data and do not need access to internal addresses.

## Risks / Trade-offs
- Public feed URLs that redirect or resolve into disallowed address space will stop working.
  - Mitigation: surface explicit log reasons and keep the allowlist/policy narrow and documented.
- Some OIDC providers with misconfigured discovery metadata may stop working.
  - Mitigation: this is a secure failure mode; broken metadata should not be trusted for token exchange.

## Migration Plan
1. Add spec deltas for auth and observability fetch hardening.
2. Implement token-endpoint validation in `web-ng`.
3. Implement core outbound fetch validation for observability refresh workers.
4. Add regression tests and update docs/task state.

## Open Questions
- Whether the core-side outbound policy should remain local to observability refreshes or be promoted later to a broader shared helper.
