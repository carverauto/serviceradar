## ADDED Requirements
### Requirement: Platform-enforced tenant namespace isolation
The shared cluster SHALL enforce a platform-managed network isolation baseline for designated tenant namespaces without requiring tenant namespace owners to author or maintain the baseline policy themselves.

#### Scenario: Labeled tenant namespace receives default deny baseline
- **GIVEN** a namespace is labeled as a tenant namespace subject to shared-cluster isolation
- **WHEN** workload pods are created in that namespace
- **THEN** ingress and egress SHALL be denied by default at the platform level
- **AND** only explicitly allowed flows SHALL be admitted

#### Scenario: Tenant namespace baseline permits only common shared-cluster dependencies
- **GIVEN** a tenant namespace subject to the shared-cluster baseline
- **WHEN** the baseline policy is evaluated
- **THEN** it SHALL allow DNS resolution to approved cluster DNS endpoints
- **AND** it SHALL allow ingress only from approved ingress-controller workloads or other explicitly approved platform entrypoints
- **AND** it SHALL NOT allow unrestricted east-west traffic to arbitrary namespaces

#### Scenario: Tenant namespace adds narrower local policy
- **GIVEN** a tenant namespace already covered by the platform baseline
- **WHEN** namespace-local `NetworkPolicy` objects are applied for application-specific flows
- **THEN** those local policies MAY allow narrower flows required by that application
- **AND** the namespace SHALL remain subject to the platform baseline default deny

### Requirement: Global network policy mutation is restricted
Only explicit platform operator identities SHALL be able to create, update, or delete Calico global or tiered network policy resources that affect shared-cluster isolation.

#### Scenario: Tenant workload identity cannot mutate global policy
- **GIVEN** a workload running with a tenant namespace service account
- **WHEN** it attempts to create, update, patch, or delete `globalnetworkpolicies.projectcalico.org`
- **THEN** the Kubernetes API SHALL deny the request

#### Scenario: Broad authenticated groups are not policy administrators
- **GIVEN** a generally authenticated Kubernetes principal that is not part of the platform operator role
- **WHEN** it attempts to modify Calico global or tiered policy resources
- **THEN** the request SHALL be denied
- **AND** the isolation baseline SHALL remain managed only by explicit operator bindings

### Requirement: Tenant namespace isolation is actively verified
The platform SHALL maintain an active verification workflow for shared-cluster isolation instead of relying only on rendered manifests.

#### Scenario: Cross-namespace reachability test fails for disallowed traffic
- **GIVEN** a verification pod running in a tenant namespace
- **WHEN** it attempts to connect to services or pods in a disallowed namespace
- **THEN** the connection SHALL fail
- **AND** the verification result SHALL be recorded for operator review

#### Scenario: Control-plane reachability test fails for non-API workloads
- **GIVEN** a verification pod representing a tenant workload that does not require Kubernetes API access
- **WHEN** it attempts to connect to disallowed control-plane endpoints
- **THEN** the connection SHALL fail
- **AND** any required exception SHALL be explicitly documented before access is granted
