## Context
Edge onboarding currently targets checkers and assumes operators manually construct agent configs. Enrollment logic is duplicated across multiple binaries, and the admin edge package UI is broken, so onboarding packages cannot be used end-to-end. Deployments also do not reliably expose a public gateway endpoint, preventing edge agents from connecting after installation. Certificate issuance via SPIFFE/SPIRE is not viable for edge agents.

## Goals / Non-Goals
- Goals:
  - Provide a single serviceradar-cli enrollment flow using edgepkg tokens for agents and collectors.
  - Ensure onboarding packages embed gateway endpoint + agent identity details.
  - Make edge onboarding UI reliable and consistent across entry points.
  - Allow Compose and Helm deployments to expose gateway endpoints for edge agents.
  - Issue agent mTLS certificates via agent-gateway instead of SPIFFE.
- Non-Goals:
  - Rework the entire edge onboarding token format beyond adding optional fields.
  - Introduce multitenancy bypasses or new routing models.

## Decisions
- Decision: Keep `edgepkg-v1` as the token format and add optional fields for agent onboarding metadata when needed.
  - Rationale: avoids breaking existing token parsing while enabling agent-specific payloads.
- Decision: Enrollment is centralized in serviceradar-cli and used by both agents and collectors.
  - Rationale: reduces duplicated logic and keeps one enrollment code path to maintain.
- Decision: Gateway endpoint is sourced from operator configuration (UI or env) and shipped inside the package payload; tokens may optionally include an override.
  - Rationale: the token should remain minimal but the agent still receives the endpoint reliably.
- Decision: Agent package UI captures an optional host IP, and enrollment auto-detects when blank.
  - Rationale: keeps zero-touch defaults while supporting NAT or pinned host addressing.
- Decision: Base URLs and endpoints default to deployment-local values (Endpoint.url, internal service names) instead of SaaS constants.
  - Rationale: OSS/on-prem installs should work without SaaS-specific defaults.
- Decision: Agent-gateway issues mTLS certificates on request from web-ng and returns an encrypted bundle for package creation.
  - Rationale: edge agents do not have SPIFFE access; the gateway already owns the trust path for agents.

## Risks / Trade-offs
- Exposing gateway endpoints in Compose/Helm may require additional security guidance (firewalling, TLS expectations).
- Gateway certificate issuance introduces a dependency on gateway availability during package creation.
- Adding optional token fields requires careful backward compatibility in Go/Rust token parsers.

## Migration Plan
1. Add gateway-issued certificate bundle generation for agent packages.
2. Add config fields for gateway endpoint and agent identity in package payloads.
3. Release agent enrollment CLI changes.
4. Update deployments to expose gateway endpoint and document required configuration.

## Open Questions
- Should the gateway endpoint be stored in a dedicated settings resource or derived from ingress/service status?
