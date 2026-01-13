## Context
Demo-staging Helm installs are expected to use SPIFFE/SPIRE for in-cluster identity. web-ng still assumes file-based mTLS when connecting to datasvc and the agent-gateway workload is not deployed by the chart, which prevents a clean, idempotent install.

## Goals / Non-Goals
- Goals:
  - Enable web-ng to connect to datasvc using SPIFFE SVIDs in Kubernetes.
  - Preserve file-based mTLS behavior for Docker Compose and non-SPIFFE environments.
  - Deploy serviceradar-agent-gateway via Helm with SPIFFE identity and cluster wiring.
  - Keep Helm installs idempotent with no manual post-install steps.
- Non-Goals:
  - Redefine tenant CA hierarchy or platform-admin cross-tenant access.
  - Replace existing file-based mTLS flows outside Kubernetes.
  - Change agent enrollment or tenant isolation behavior.

## Decisions
- Decision: Use env-driven mode selection for web-ng datasvc client (SPIFFE vs file-based mTLS).
  - Rationale: Keeps backward compatibility with Docker Compose while enabling SPIFFE in-cluster.
- Decision: Deploy agent-gateway as an optional Helm workload controlled by values.
  - Rationale: Maintains flexibility for minimal installs while supporting full platform topology.
- Decision: web-ng uses SPIFFE for in-cluster gRPC to datasvc; agent-gateway uses tenant-CA mTLS for edge gRPC and ERTS for core connectivity (no SPIFFE on gateway).
  - Rationale: SPIFFE SVIDs would conflict with tenant-CA validation on the gateway and are not needed for its current responsibilities.

## Risks / Trade-offs
- Risk: Mixed TLS modes (SPIFFE vs file-based) could misconfigure services if envs are inconsistent.
  - Mitigation: Provide explicit Helm defaults and validation in values comments.
- Risk: Agent-gateway defaults could start before SPIRE is ready, causing transient failures.
  - Mitigation: Use readiness probes and retry logic; align SPIRE and gateway startup ordering in Helm.

## Migration Plan
1. Add SPIFFE mode toggles and env wiring for web-ng datasvc connections.
2. Add agent-gateway Helm templates and values; default to enabled in demo-staging.
3. Roll Helm upgrade; verify datasvc connectivity, NATS bootstrap, and gateway readiness.

## Open Questions
- Should web-ng use SPIFFE for any other internal calls beyond datasvc (e.g., core gRPC, SRQL)?
- Do we need a dedicated SPIFFE ID convention for web-ng <-> datasvc gRPC (beyond current service account naming)?
