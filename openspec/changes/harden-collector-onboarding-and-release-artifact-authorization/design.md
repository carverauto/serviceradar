## Context
ServiceRadar has two remaining privileged bootstrap and delivery paths that still rely on weak bearer-style metadata:

- Collector enrollment uses an unsigned token that can carry a Core API base URL.
- Gateway-served release artifacts are requested with headers that name a rollout target and command, but the authorization path does not bind those headers to the caller's mTLS identity.

Both paths need to be hardened without breaking the existing deployment model where edge workloads only reach trusted ServiceRadar endpoints.

## Goals / Non-Goals
- Goals:
  - Make collector token metadata tamper-evident before the client trusts it.
  - Remove unsigned enrollment token compatibility paths so clients only accept signed tokens.
  - Require gateway-served release artifact downloads to match the authenticated agent identity.
- Non-Goals:
  - Replacing collector package delivery semantics in Core.
  - Replacing the existing rollout command model or mirrored object storage design.
  - Redesigning SPIFFE or mTLS identity issuance.

## Decisions
- Decision: treat collector enrollment tokens like agent onboarding tokens from a trust perspective.
  - Rationale: they also deliver privileged config and credentials onto a host.
- Decision: remove support for legacy unsigned agent and collector token formats instead of preserving a compatibility mode.
  - Rationale: unsigned compatibility paths keep the downgrade surface alive and are no longer needed operationally.
- Decision: authorize release artifact downloads against the caller's mTLS identity and the intended rollout target.
  - Rationale: target and command identifiers alone are bearer tokens if they are not tied to the caller identity.

## Risks / Trade-offs
- Existing collector quick-start commands may need regeneration once signed tokens are enabled.
  - Mitigation: update generated commands and docs in the same change.
- Tightening release artifact authorization may reveal identity mismatches in environments with inconsistent agent IDs or certificate subject mapping.
  - Mitigation: add focused tests and explicit logging for authorization failures.

## Migration Plan
1. Add the new collector token trust model and remove unsigned parsing paths.
2. Update generated collector install flows to emit signed tokens only.
3. Bind gateway artifact authorization to authenticated agent identity.
4. Validate the tightened behavior with targeted tests and compile checks.
