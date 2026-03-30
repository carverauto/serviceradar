## MODIFIED Requirements
### Requirement: Default Kubernetes installs omit SPIRE dependencies
The default Helm chart render and default Kubernetes manifest path SHALL NOT require SPIRE CRDs, SPIRE workloads, or SPIRE-specific cluster-scoped resources in order to deploy ServiceRadar with internal mTLS enabled.

#### Scenario: Default Helm render omits SPIRE resources
- **GIVEN** a Helm render with default values
- **WHEN** `spire.enabled` is not explicitly enabled
- **THEN** no SPIRE CRDs, SPIRE server, SPIRE agent, or SPIRE controller-manager resources are present

#### Scenario: Optional SPIFFE mode defaults to internal-only SPIRE exposure
- **GIVEN** a Helm render with `spire.enabled=true`
- **WHEN** the operator does not explicitly request external SPIRE publication
- **THEN** the SPIRE server service is internal-only
- **AND** the SPIRE health endpoint is not published through the service by default

#### Scenario: Optional SPIFFE mode requires verified kubelet attestation by default
- **GIVEN** a Helm render with `spire.enabled=true`
- **WHEN** the operator does not explicitly enable an insecure attestation escape hatch
- **THEN** the SPIRE agent workload attestor does not disable kubelet verification
