## Context
ServiceRadar currently runs in a shared Kubernetes cluster that hosts both platform infrastructure and separate namespace-scoped application stacks. The immediate concern is not application multitenancy inside ServiceRadar itself; it is shared-cluster risk when a semi-trusted namespace or a new admin-managed application is compromised.

April 1, 2026 verification showed:

- `kubectl auth whoami` resolves the current kubeconfig to `system:admin` in `system:masters`
- `biasarena-qa`, `biasarena-production`, and `asset-hoster-production` use `restricted` Pod Security admission and namespaced default-deny `NetworkPolicy`
- the same tenant workloads run on the `default` service account and mount projected service-account tokens
- Calico binds `calico-tiered-policy-passthrough` to `system:authenticated`, granting create/update/delete on `globalnetworkpolicies.projectcalico.org` and `networkpolicies.projectcalico.org`
- only a subset of namespaces have any `NetworkPolicy`, and many namespaces are not labeled for `restricted` Pod Security enforcement
- Kyverno is intentionally scoped to `demo`, so cluster-wide protection for the other admin's namespaces must come from platform controls rather than tenant-owned admission policy

## Goals
- Remove shared cluster-admin credentials from routine human workflows.
- Make namespace compromise materially harder to turn into cross-namespace or cluster-wide compromise.
- Enforce baseline isolation for tenant namespaces without requiring each namespace owner to write or maintain Kyverno policy.
- Preserve narrow, explicit exceptions for infrastructure namespaces that legitimately require privileged operation.
- Produce verifiable evidence that the controls are working.

## Non-Goals
- Introduce ServiceRadar product-level multitenancy features.
- Force every non-ServiceRadar namespace to adopt signed-image verification or tenant-authored policy bundles.
- Eliminate all privileged infrastructure namespaces such as CNI, storage, or GPU operators.

## Decisions

### 1. Separate human access from workload access
Human access and workload access address different threat models and must be designed separately.

- Human access moves to individual identities backed by Authentik and Kubernetes OIDC-compatible authentication.
- Routine administrators receive only the cluster or namespace roles they require.
- A break-glass admin credential may remain X.509-based, but it must be rotated, stored offline, and excluded from regular operations.
- Workload identities continue to use Kubernetes service accounts, but service-account token exposure is minimized.

### 2. Use platform-enforced Calico policy for tenant namespaces
Kyverno remains scoped to `demo`, so cross-namespace containment for other namespaces will be enforced with Calico and namespace labels.

- Platform operators define one or more namespace labels that opt namespaces into shared-cluster tenant isolation.
- Calico `GlobalNetworkPolicy` applies a baseline default deny to those namespaces.
- Baseline allow rules admit only the minimum common traffic required for tenant apps, such as DNS and ingress-controller traffic.
- Namespace-local `NetworkPolicy` may add narrower app-specific rules, but tenant isolation must not depend solely on namespace owners remembering to write them correctly.

### 3. Remove cluster-wide Calico policy mutation from broad principals
No workload identity or general authenticated principal should be able to mutate cluster-wide network controls.

- The existing `system:authenticated` passthrough binding is incompatible with shared-cluster isolation goals.
- Calico global-policy mutation is restricted to an explicit platform-operator role or group.
- Verification must include `kubectl auth can-i` checks for representative tenant service accounts.

### 4. Default tenant workloads away from Kubernetes API access
If a workload does not need the Kubernetes API, it should not receive a projected token.

- Tenant deployments default to `automountServiceAccountToken: false`.
- API-aware workloads must opt in with a dedicated service account and narrowly scoped RBAC.
- Verification must inspect pod specs and mounted projected token volumes, not just deployment YAML defaults.

### 5. Verify controls actively, not only declaratively
The platform needs operational proof, not just manifests.

- Verification includes active connectivity tests from tenant namespaces to other namespaces, the API server, and restricted services.
- Verification includes RBAC checks for service accounts and human roles.
- Verification includes audit evidence for namespace label changes, role bindings, and policy mutations.
- Falco findings must be forwarded to an actionable destination so runtime anomalies are visible.

## Risks and tradeoffs
- Tightening Calico and service-account defaults may break operators or controllers that rely on undocumented API or network access. Rollout needs staged label-based enforcement and exception review.
- OIDC migration for Kubernetes depends on the cluster distribution's supported authentication integration. The proposal defines the target access model, but implementation details may differ between kubeadm, RKE2, K3s, or managed distributions.
- Some infrastructure namespaces must remain privileged. The design therefore distinguishes labeled tenant namespaces from platform infrastructure namespaces instead of applying one uniform policy to all namespaces.
