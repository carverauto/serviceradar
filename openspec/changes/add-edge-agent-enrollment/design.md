## Context
Edge onboarding currently targets checkers and assumes operators manually construct agent configs. The agent binary lacks an enrollment flow and the admin edge package UI is broken, so onboarding packages cannot be used end-to-end. Deployments also do not reliably expose a public gateway endpoint, preventing edge agents from connecting after installation.

## Goals / Non-Goals
- Goals:
  - Provide a first-class serviceradar-agent enrollment flow using edgepkg tokens.
  - Ensure onboarding packages embed gateway endpoint + agent identity details.
  - Make edge onboarding UI reliable and consistent across entry points.
  - Allow Compose and Helm deployments to expose gateway endpoints for edge agents.
- Non-Goals:
  - Rework the entire edge onboarding token format beyond adding optional fields.
  - Introduce multitenancy bypasses or new routing models.

## Decisions
- Decision: Keep `edgepkg-v1` as the token format and add optional fields for agent onboarding metadata when needed.
  - Rationale: avoids breaking existing token parsing while enabling agent-specific payloads.
- Decision: Agent enrollment writes bootstrap config (`agent.json`) and certs atomically to standard paths and does not require serviceradar-cli.
  - Rationale: aligns with sysmon checker onboarding and reduces operator steps.
- Decision: Gateway endpoint is sourced from operator configuration (UI or env) and shipped inside the package payload; tokens may optionally include an override.
  - Rationale: the token should remain minimal but the agent still receives the endpoint reliably.
- Decision: Agent package UI captures an optional host IP, and enrollment auto-detects when blank.
  - Rationale: keeps zero-touch defaults while supporting NAT or pinned host addressing.
- Decision: Base URLs and endpoints default to deployment-local values (Endpoint.url, internal service names) instead of SaaS constants.
  - Rationale: OSS/on-prem installs should work without SaaS-specific defaults.

## Risks / Trade-offs
- Exposing gateway endpoints in Compose/Helm may require additional security guidance (firewalling, TLS expectations).
- Adding optional token fields requires careful backward compatibility in Go/Rust token parsers.

## Migration Plan
1. Add config fields for gateway endpoint and agent identity in package payloads.
2. Release agent enrollment CLI changes.
3. Update deployments to expose gateway endpoint and document required configuration.

## Open Questions
- Should the gateway endpoint be stored in a dedicated settings resource or derived from ingress/service status?
