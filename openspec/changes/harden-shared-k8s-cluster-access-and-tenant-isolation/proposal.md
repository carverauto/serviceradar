# Change: Harden shared Kubernetes cluster access and tenant isolation

## Why
The current shared Kubernetes cluster relies on a copied `system:admin` kubeconfig for human access and mixes trusted platform workloads with semi-trusted tenant namespaces. As verified on April 1, 2026, the target tenant namespaces (`biasarena-qa`, `biasarena-production`, and `asset-hoster-production`) already use namespace-local `NetworkPolicy` default-deny rules and `restricted` Pod Security admission, but the cluster still exposes high-risk lateral movement paths:

- the shared kubeconfig authenticates as `system:admin` in `system:masters`
- tenant workloads run on the `default` service account with projected API tokens mounted
- Calico `ClusterRole` access for `globalnetworkpolicies.projectcalico.org` and `networkpolicies.projectcalico.org` is granted to `system:authenticated`
- many namespaces still lack any `NetworkPolicy` baseline or `restricted` Pod Security enforcement
- Falco is deployed but alert delivery and audit evidence are not wired to an operational sink

The cluster needs platform-enforced controls that reduce blast radius even when a tenant namespace is compromised, without requiring every namespace owner to adopt Kyverno policy management.

## What Changes
- Add a shared-cluster access model that replaces shared X.509 admin kubeconfigs with individual Authentik-backed user authentication and least-privilege RBAC.
- Define break-glass cluster administration so a retained admin certificate remains tightly controlled, audited, and excluded from day-to-day use.
- Add platform-managed Calico baseline isolation for designated tenant namespaces using namespace labels and global policy, rather than tenant-authored policy alone.
- Require service-account hardening for tenant workloads, including disabling token automount where Kubernetes API access is not required.
- Remove broad Calico policy write access from `system:authenticated` and other workload identities that do not explicitly need it.
- Add audit and verification requirements so the platform can prove tenant namespaces cannot reach disallowed namespaces, control-plane endpoints, or privileged policy APIs.
- Route Falco and policy/audit findings to an actionable sink instead of leaving detections only in pod logs.

## Impact
- Affected specs: `kubernetes-network-policy`, `kubernetes-cluster-access`
- Affected code and config: cluster bootstrap manifests, RBAC bindings, Calico policy manifests, namespace labeling conventions, Authentik/OIDC cluster auth configuration, workload manifests, and operational runbooks
- Operational impact: tenant namespace onboarding gains platform labels and baseline controls; human admins move from shared kubeconfigs to individual identities
