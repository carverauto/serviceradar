## MODIFIED Requirements
### Requirement: Platform SPIFFE mTLS for internal gRPC

Platform services that communicate with datasvc via gRPC (web-ng, core-elx) SHALL support SPIFFE SVID-based mTLS inside Kubernetes clusters. Datasvc SHALL validate SPIFFE identities for those clients. When SPIFFE Workload API mode is enabled, Elixir services SHALL fetch X.509 SVIDs via the SPIRE agent socket. When SPIFFE is disabled, those services SHALL use file-based mTLS configuration so Docker Compose and non-SPIFFE environments remain functional.

#### Scenario: SPIFFE-enabled web-ng connects to datasvc
- **GIVEN** SPIFFE is enabled for the cluster
- **AND** web-ng has access to the SPIRE agent socket
- **WHEN** web-ng establishes a gRPC channel to datasvc
- **THEN** the connection uses a SPIFFE SVID for client authentication
- **AND** datasvc validates the SPIFFE identity of web-ng

#### Scenario: SPIFFE Workload API supplies SVIDs for Elixir services
- **GIVEN** SPIFFE Workload API mode is enabled
- **AND** the SPIRE agent socket is available in the pod
- **WHEN** web-ng or core-elx needs a gRPC client certificate
- **THEN** the service fetches an X.509 SVID and bundle from the Workload API
- **AND** the resulting mTLS credentials are used for the gRPC connection

#### Scenario: SPIFFE disabled uses file-based mTLS
- **GIVEN** SPIFFE is disabled for the deployment
- **WHEN** web-ng connects to datasvc
- **THEN** web-ng uses file-based mTLS certificates configured via environment variables
- **AND** the connection succeeds without SPIFFE dependencies

#### Scenario: Shared Go gRPC clients reject implicit insecure transport
- **GIVEN** a Go service constructs a shared gRPC client without a security provider or security mode
- **WHEN** the connection options are built
- **THEN** the client SHALL fail closed instead of silently using plaintext transport

#### Scenario: Shared Go SPIFFE clients require expected server identity
- **GIVEN** a Go service uses the shared SPIFFE security provider
- **AND** no expected server SPIFFE ID or equivalent trust constraint is configured
- **WHEN** client credentials are requested
- **THEN** the provider SHALL fail closed instead of authorizing any SPIFFE endpoint

#### Scenario: Shared Go SPIFFE servers require client trust constraints
- **GIVEN** a Go service uses the shared SPIFFE security provider for server credentials
- **AND** no trust-domain or equivalent client identity constraint is configured
- **WHEN** server credentials are requested
- **THEN** the provider SHALL fail closed instead of authorizing any SPIFFE caller
