## 1. CRD Definitions
- [ ] Define `TenantWorkloadTemplate` CRD (cluster-scoped)
- [ ] Define `TenantWorkloadSet` CRD (namespaced)
- [ ] Add Helm manifests for CRDs

## 2. Operator: NATS -> CRD
- [ ] Extend operator to create/update/delete `TenantWorkloadSet` from tenant lifecycle events
- [ ] Map tenant lifecycle payload to workload list (default templates for agent-gateway + zen-consumer)

## 3. Operator: CRD Reconciliation
- [ ] Implement reconciliation logic for `TenantWorkloadSet` + template refs
- [ ] Ensure ServiceAccount creation with `automountServiceAccountToken: false`
- [ ] Ensure ClusterSPIFFEID creation per workload
- [ ] Render workloads as Deployment or DaemonSet based on template
- [ ] Create Service only when template specifies it
- [ ] Create/update ConfigMap/Secret resources as required

## 4. Zen Consumer Defaults
- [ ] Update template defaults to run zen-consumer as a DaemonSet
- [ ] Ensure zen-consumer has no Service by default

## 5. Helm & Docs
- [ ] Add default template objects to Helm chart
- [ ] Document CRD usage + lifecycle flow in `docs/docs/helm-configuration.md`

## 6. Validation
- [ ] Run `openspec validate add-tenant-workload-crds --strict`
