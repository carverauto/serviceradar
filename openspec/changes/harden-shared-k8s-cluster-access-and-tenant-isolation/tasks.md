## 1. Discovery and control design
- [ ] 1.1 Inventory current human cluster access paths, including copied kubeconfigs, bootstrap certificates, and existing RBAC bindings.
- [ ] 1.2 Inventory current tenant namespaces, namespace labels, service accounts, projected API-token usage, and Calico/Kubernetes network policy coverage.
- [ ] 1.3 Define the namespace-label contract that identifies namespaces managed by platform tenant-isolation policy.

## 2. Human authentication and authorization
- [ ] 2.1 Design Authentik-backed Kubernetes authentication for individual users, including group claims and cluster role mapping.
- [ ] 2.2 Define least-privilege roles for non-platform admins and remove day-to-day use of shared `system:admin` kubeconfigs.
- [ ] 2.3 Define break-glass admin access, credential rotation, storage, and usage logging requirements.

## 3. Tenant namespace isolation
- [ ] 3.1 Design Calico global baseline policy for labeled tenant namespaces with default deny, DNS allowance, ingress controller allowance, and explicit egress exceptions.
- [ ] 3.2 Remove broad Calico policy-management rights from `system:authenticated` and other unintended principals.
- [ ] 3.3 Define service-account token hardening for tenant workloads, including `automountServiceAccountToken: false` by default and explicit opt-in for API-aware workloads.
- [ ] 3.4 Define Pod Security admission baseline requirements for tenant namespaces and document allowed exceptions for infrastructure namespaces.

## 4. Verification and detection
- [ ] 4.1 Define active validation workflows that test cross-namespace, control-plane, and policy-API reachability from representative tenant pods.
- [ ] 4.2 Define audit-log retention and query requirements for RBAC changes, namespace label changes, and policy mutations.
- [ ] 4.3 Define Falco output routing and alert ownership so runtime detections reach an actionable destination.

## 5. Rollout and operations
- [ ] 5.1 Document phased rollout order for access migration, policy enforcement, and exception handling.
- [ ] 5.2 Document rollback and emergency bypass procedures that do not permanently reopen the shared-cluster attack surface.
- [ ] 5.3 Update operational runbooks for tenant onboarding, namespace hardening, and periodic verification.
