## ADDED Requirements
### Requirement: Helm NetworkPolicy Controls
The Helm chart SHALL provide an optional Kubernetes `NetworkPolicy` that enforces default-deny egress for selected ServiceRadar pods and allows only explicitly configured destinations.

#### Scenario: NetworkPolicy disabled by default
- **WHEN** `networkPolicy.enabled` is `false`
- **THEN** the chart SHALL NOT render any Kubernetes `NetworkPolicy` resources.

#### Scenario: NetworkPolicy enabled with namespace/DNS allow list
- **WHEN** `networkPolicy.enabled` is `true` and `networkPolicy.egress.allowDefaultNamespace` is `true`
- **THEN** the rendered policy SHALL allow egress to pods in the `default` namespace.
- **WHEN** `networkPolicy.egress.allowSameNamespace` is `true`
- **THEN** the rendered policy SHALL allow egress to pods in the release namespace.
- **WHEN** `networkPolicy.egress.allowKubeAPIServer` is `true`
- **THEN** the rendered policy SHALL allow egress to the kube-apiserver service and endpoint IPs discovered during Helm rendering.
- **WHEN** `networkPolicy.egress.allowDNS` is `true`
- **THEN** the rendered policy SHALL allow UDP/TCP 53 to the `kube-system` namespace.
- **WHEN** `networkPolicy.egress.allowedCIDRs` is populated
- **THEN** the rendered policy SHALL allow egress to those CIDR ranges.

### Requirement: Calico Deny Logging
When Calico logging is enabled, the Helm chart SHALL render a Calico `NetworkPolicy` that mirrors the allow list and logs denied egress before denying it.

#### Scenario: Calico deny logging enabled
- **WHEN** `networkPolicy.calicoLogDenied.enabled` is `true`
- **THEN** the chart SHALL render a Calico `NetworkPolicy` with allow rules matching the Kubernetes policy and a final log+deny rule for all other egress.

### Requirement: Demo Defaults Enable Egress Controls
The demo Helm values SHALL enable the egress controls and deny logging.

#### Scenario: Demo values render policies
- **WHEN** Helm templates are rendered with `values-demo.yaml`
- **THEN** the output SHALL include both the Kubernetes `NetworkPolicy` and the Calico `NetworkPolicy` resources.
