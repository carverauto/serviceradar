## MODIFIED Requirements
### Requirement: Platform SPIFFE mTLS for internal gRPC
Platform services, bootstrap tooling, and shipped runtime daemons that communicate over internal gRPC SHALL use authenticated transport and SHALL NOT silently fall back to plaintext when security configuration is omitted or explicitly set to insecure modes. Datasvc SHALL validate SPIFFE identities for platform services. When SPIFFE Workload API mode is enabled, Elixir and Rust services SHALL fetch X.509 SVIDs via the SPIRE agent socket. When SPIFFE is disabled for platform services, those services SHALL use file-based mTLS configuration so Docker Compose and non-SPIFFE environments remain functional.

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

#### Scenario: Bootstrap tooling rejects missing transport security
- **GIVEN** bootstrap tooling needs to register a configuration template with core over gRPC
- **WHEN** `CORE_SEC_MODE` is empty or `none`
- **THEN** the tooling SHALL reject the registration attempt before dialing core
- **AND** it SHALL NOT fall back to plaintext transport

#### Scenario: Flowgger rejects insecure gRPC sidecar transport
- **GIVEN** `rust/flowgger` is configured with `grpc.listen_addr`
- **WHEN** `grpc.mode` is `none` or `grpc.mode = "mtls"` is configured without the required certificate paths
- **THEN** the gRPC sidecar configuration SHALL be rejected
- **AND** flowgger SHALL NOT serve the health sidecar over plaintext
