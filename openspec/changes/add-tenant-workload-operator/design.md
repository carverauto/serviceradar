## Context
We need per-tenant workloads (agent-gateway, serviceradar-zen, and future services) created automatically in Kubernetes as tenants are provisioned. The core service must not access Kubernetes APIs, so the automation must be driven by events and a dedicated operator with least-privilege credentials.

## Goals / Non-Goals
- Goals:
  - Event-driven tenant workload provisioning in Kubernetes.
  - Least-privilege NATS account for the operator.
  - Core emits events but never touches k8s APIs.
  - Docker Compose remains single-tenant and static.
- Non-Goals:
  - Supporting multi-tenant automation in Docker Compose.
  - Replacing the existing edge onboarding flow for off-cluster agents.

## Decisions
- Emit tenant lifecycle events via NATS JetStream and have the operator subscribe and reconcile state.
- Implement the operator in Go using controller-runtime and CRDs or direct event reconciliation.
- Create a dedicated NATS account for the operator during platform bootstrap; store credentials in a Kubernetes Secret that the operator mounts.
- Operator obtains tenant-specific artifacts (mTLS certs, NATS creds, gateway/zen config) by calling core APIs and persists them as Kubernetes Secrets.

## Risks / Trade-offs
- Event ordering and retry handling must be idempotent to avoid duplicate provisioning.
- Operator credentials become critical infrastructure; rotate via bootstrap workflow.
- Per-tenant workloads may increase cluster overhead; plan for HPA and resource limits.

## Migration Plan
1. Add tenant lifecycle event publisher to core.
2. Deploy the operator with NATS credentials and RBAC.
3. Migrate tenant provisioning to emit events and verify operator reconciliation.

## Open Questions
- Namespace strategy: per-tenant namespaces vs shared namespace with labels/NetworkPolicies.
- SPIFFE: should in-cluster workloads use SPIFFE identities instead of static cert Secrets.
- Event schema: define required fields for scale targets, regions, and optional workloads.
