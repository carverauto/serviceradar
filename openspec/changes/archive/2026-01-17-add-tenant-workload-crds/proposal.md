# Change: Add tenant workload CRDs and CRD-driven operator

## Why
We need a reusable, secure, and extensible way to provision per-tenant workloads in Kubernetes (zen consumers, agent gateways, future services) without granting any workload access to Kubernetes APIs. The current operator hard-codes workload logic, which makes adding new tenant services brittle and risky.

## What Changes
- Introduce Kubernetes CRDs to describe tenant workload templates and per-tenant workload sets.
- Extend the tenant workload operator to reconcile these CRDs into actual Kubernetes resources (DaemonSets/Deployments, ServiceAccounts, ClusterSPIFFEIDs, ConfigMaps, Secrets).
- Keep the operator NATS-event driven: tenant lifecycle events from core create/update/delete the per-tenant CRs, and reconciliation derives the runtime resources.
- Provide default templates for `agent-gateway` and `zen-consumer` (zen defaults to DaemonSet, no Service).

## Impact
- Affected specs: tenant-workload-orchestration (new), tenant-isolation (SPIFFE identity enforcement).
- Affected code: Go operator, Helm charts, CRD manifests, core tenant lifecycle event payloads (if new fields are required).
- **Security**: operator retains exclusive Kubernetes API access; tenant workloads do not access the API.
