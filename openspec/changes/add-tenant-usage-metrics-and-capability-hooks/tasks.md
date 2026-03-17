## 1. Spec
- [x] 1.1 Add the `tenant-capabilities` spec for usage metrics and capability flags
- [x] 1.2 Validate the change with `openspec validate add-tenant-usage-metrics-and-capability-hooks --strict`

## 2. Usage Metrics
- [x] 2.1 Export a canonical Prometheus metric for current managed-device count
- [x] 2.2 Export Prometheus metrics for collector inventory or enabled collector counts
- [x] 2.3 Document the intended meaning of each metric so external systems do not infer different counts

## 3. Capability Hooks
- [x] 3.1 Add a generic runtime capability configuration contract
- [x] 3.2 Gate collector-related UI paths on the capability contract
- [x] 3.3 Gate collector-related backend actions on the capability contract
- [x] 3.4 Preserve current OSS behavior when no capability contract is supplied

## 4. Follow-on Enforcement
- [x] 4.1 Add warning or advisory behavior when managed-device counts exceed externally supplied limits
- [x] 4.2 Leave billing and commercial plan logic outside OSS
