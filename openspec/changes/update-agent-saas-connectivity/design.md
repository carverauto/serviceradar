## Context
ServiceRadar currently relies on pollers to reach agents over gRPC. This requires inbound firewall access to customer networks and does not fit the SaaS deployment model. Agents already have mTLS credentials and can connect outbound, so the control plane should accept agent-initiated connections and provide configuration driven by tenant data in CNPG.

## Goals / Non-Goals
- Goals:
  - Agents initiate outbound-only gRPC connections to the SaaS control plane.
  - Enrollment and status updates are handled via Ash resources and pubsub events.
  - Configuration is generated from tenant data in CNPG and delivered with versioning.
  - Agent bootstrap config is minimal (endpoint + mTLS credentials only).
- Non-Goals:
  - Rewriting the agent codebase or checker binaries.
  - Replacing SPIFFE/SPIRE identity or mTLS bootstrap workflows.
  - Implementing server-initiated streaming config in this phase.

## Decisions
- Decision: Introduce an agent-facing ingress service (likely a refactor of the poller binary) that terminates agent mTLS gRPC, validates the client certificate chain against the platform root CA, derives tenant identity from the server-validated issuer certificate, and forwards enrollment/config requests to core-elx.
- Decision: Replace `PollerService` with `AgentGatewayService` and rename status payloads to gateway terminology while preserving the existing streaming/chunked status upload flow for compatibility with serviceradar-sync.
- Decision: Tenant identity is resolved by matching the client certificate issuer CA to the tenant CA stored in `ServiceRadar.Edge.TenantCA`, using a SHA-256 SPKI hash computed from the validated issuer certificate public key. Component identity and partition are derived from the client certificate CN format `<component-id>.<partition-id>.<tenant-slug>.serviceradar`, and `Hello` data cannot override these values.
- Decision: Add gRPC methods `Hello` and `GetConfig`; `Hello` is required before `GetConfig` and includes agent identity, capabilities, and version metadata.
- Decision: Core-elx uses Ash resources to register new agents, update online status, and generate versioned configuration from tenant data stored in CNPG.
- Decision: `GetConfig` accepts a config version/etag and returns `not_modified` when no changes exist; agents poll every 5 minutes.

## Alternatives considered
- Reverse tunnels or agent-initiated NAT traversal: adds operational complexity and is harder to secure.
- Direct agent connections to core-elx: increases load on core and removes the option to scale gRPC ingress separately.
- Server-side streaming for config push: attractive long-term, but higher complexity than periodic polling.

## Risks / Trade-offs
- Config propagation delay up to 5 minutes.
- Additional service to operate and scale for agent ingress.
- Migration complexity for existing poller-driven deployments.

## Migration Plan
- Introduce new gRPC service and run in parallel with the existing poller workflow.
- Update onboarding bundles and agent binaries to use the new hello/config flow.
- Gradually disable poller-to-agent orchestration once agent connectivity is proven in production.

## Open Questions
- Where to persist config versions (CNPG table vs KV) for efficient lookup.
- Backward compatibility strategy for legacy agents during rollout.
