## 1. CRD Definitions
- [x] Define `TenantWorkloadTemplate` CRD (cluster-scoped)
- [x] Define `TenantWorkloadSet` CRD (namespaced)
- [x] Add Helm manifests for CRDs

## 2. Operator: NATS -> CRD
- [x] Extend operator to create/update/delete `TenantWorkloadSet` from tenant lifecycle events
- [x] Map tenant lifecycle payload to workload list (default templates for agent-gateway + zen-consumer)

## 3. Operator: CRD Reconciliation
- [x] Implement reconciliation logic for `TenantWorkloadSet` + template refs
- [x] Ensure ServiceAccount creation with `automountServiceAccountToken: false`
- [x] Ensure ClusterSPIFFEID creation per workload
- [x] Render workloads as Deployment or DaemonSet based on template
- [x] Create Service only when template specifies it
- [x] Create/update ConfigMap/Secret resources as required

## 4. Zen Consumer Defaults
- [x] Update template defaults to run zen-consumer as a DaemonSet
- [x] Ensure zen-consumer has no Service by default

## 5. Helm & Docs
- [x] Add default template objects to Helm chart
- [x] Document CRD usage + lifecycle flow in `docs/docs/helm-configuration.md`

## 6. Validation
- [x] Run `openspec validate add-tenant-workload-crds --strict`
