## MODIFIED Requirements

### Requirement: Platform mTLS for internal gRPC

Platform services that communicate internally over gRPC (including web-ng, core-elx, and datasvc-related clients) SHALL support Secret-backed mTLS certificates mounted into workloads as the default Kubernetes runtime model. When SPIFFE is explicitly enabled for a deployment, those services SHALL also support SPIFFE/SVID-based mTLS through the SPIRE Workload API. Docker Compose and other non-SPIFFE environments SHALL continue to use mounted certificate files.

#### Scenario: Default Helm install uses Secret-backed mTLS

- **GIVEN** a Helm install that does not explicitly enable SPIFFE/SPIRE
- **WHEN** web-ng or core-elx establishes an internal gRPC connection
- **THEN** the service uses certificate, key, and CA files from mounted Kubernetes `Secret`s
- **AND** the connection succeeds without requiring a SPIRE workload socket

#### Scenario: SPIFFE Workload API supplies SVIDs when explicitly enabled

- **GIVEN** SPIFFE is explicitly enabled for the deployment
- **AND** the SPIRE agent socket is available in the pod
- **WHEN** web-ng or core-elx needs a gRPC client certificate
- **THEN** the service fetches an X.509 SVID and bundle from the Workload API
- **AND** the resulting mTLS credentials are used for the gRPC connection

## ADDED Requirements

### Requirement: Default Kubernetes installs omit SPIRE dependencies

The default Helm chart render and default Kubernetes manifest path SHALL NOT require SPIRE CRDs, SPIRE workloads, or SPIRE-specific cluster-scoped resources in order to deploy ServiceRadar with internal mTLS enabled.

#### Scenario: Default Helm render omits SPIRE resources

- **GIVEN** `helm template serviceradar ./helm/serviceradar` with default values
- **WHEN** the rendered manifests are inspected
- **THEN** no SPIRE CRDs, SPIRE server, SPIRE agent, or SPIRE controller-manager resources are present
- **AND** workloads still receive the certificate material needed for internal mTLS

#### Scenario: Optional SPIFFE mode still renders identity-plane resources

- **GIVEN** a Helm render with SPIFFE/SPIRE explicitly enabled
- **WHEN** the rendered manifests are inspected
- **THEN** the SPIRE resources required for that mode are present
- **AND** workloads can use SPIFFE identities instead of Secret-backed runtime certificates
