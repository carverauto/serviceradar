# Tenant Workload CRDs Design

## Goals
- Define a generic, reusable mechanism for per-tenant workload provisioning.
- Keep Kubernetes API access isolated to the operator.
- Preserve NATS-based tenant lifecycle signaling from core.
- Support SPIFFE identity per tenant/workload.
- Make it easy to add new tenant workloads without touching operator logic.

## Non-Goals
- Supporting multi-tenant workload provisioning in Docker Compose.
- Exposing Kubernetes APIs to tenant workloads.
- Replacing SPIRE or NATS-based credential distribution.

## Architecture

### Event-Driven Source of Truth
1. Core emits tenant lifecycle events to the `TENANT_PROVISIONING` stream.
2. The operator consumes events and creates/updates/deletes a `TenantWorkloadSet` CR per tenant.
3. A Kubernetes controller loop reconciles `TenantWorkloadSet` + `TenantWorkloadTemplate` CRs to runtime resources.

### CRDs

#### TenantWorkloadTemplate (cluster-scoped)
Defines a reusable template for a single workload type.

Fields (draft):
- `spec.workloadType`: `agent-gateway`, `zen-consumer`, etc.
- `spec.defaultKind`: `Deployment` | `DaemonSet`
- `spec.container`: image, command, args, env, ports
- `spec.resources`: optional requests/limits
- `spec.service`: optional Service spec (only when needed)
- `spec.spiffe`: serviceAccountName pattern + SPIFFE ID template
- `spec.natsCreds`: whether tenant creds secret is required
- `spec.config`: optional config map spec

#### TenantWorkloadSet (namespaced)
Represents the workload set for a single tenant.

Fields (draft):
- `spec.tenantId`
- `spec.tenantSlug`
- `spec.workloads`: list of {`templateRef`, `replicas`, `overrides`}

The operator owns creation of this CR from NATS events. Manual changes are allowed for advanced use, but the operator remains the source of truth.

### Reconciliation
For each workload in `TenantWorkloadSet`:
- Create ServiceAccount with `automountServiceAccountToken: false`.
- Create ClusterSPIFFEID for workload pods to mint tenant-specific SPIFFE IDs.
- Create runtime resources based on template kind:
  - `zen-consumer`: DaemonSet, no Service by default.
  - `agent-gateway`: Deployment + Service.
- Inject tenant identifiers and NATS creds secret references.

### SPIFFE Identity
SPIFFE IDs encode tenant identity (e.g., `spiffe://<trust-domain>/ns/<namespace>/sa/serviceradar-<workload>-<tenant>`). The operator manages the ClusterSPIFFEID to bind pods to the correct identity.

### Credential Flow
- Operator requests tenant NATS creds from core API (existing endpoint).
- Operator stores creds in a per-tenant Secret referenced by workloads.

## Security
- Only the operator ServiceAccount has Kubernetes RBAC permissions.
- Workloads run with minimal ServiceAccount permissions and do not need Kubernetes API access.
- Tenant NATS creds are scoped to tenant-specific NATS accounts.

## Operational Notes
- CRDs live in the Helm chart and are installed with the operator.
- `TenantWorkloadTemplate` objects are shipped for agent-gateway and zen-consumer; additional templates can be applied later.
