## ADDED Requirements

### Requirement: Rust sysmon checker supports edge onboarding
The Rust-based sysmon checker SHALL support edge onboarding via token-based bootstrap, matching the functionality available in sysmon-osx, to enable zero-touch deployment on Linux edge nodes.

#### Scenario: mTLS onboarding via CLI flags
- **WHEN** an operator runs `serviceradar-sysmon-checker --mtls --token <token> --host <core-or-bootstrap>` on a Linux edge host
- **THEN** sysmon SHALL download an mTLS bundle (CA, client cert/key, endpoints) from Core, install credentials to the configured cert directory, and start the gRPC server with mTLS enabled
- **AND** the poller SHALL accept connections from the checker because the client certificate chains to the trusted CA.

#### Scenario: SPIRE-based onboarding via environment variables
- **WHEN** the `ONBOARDING_TOKEN` and `KV_ENDPOINT` environment variables are set
- **THEN** sysmon SHALL download the edge onboarding package from Core, configure SPIRE workload API credentials, generate a service config with SPIFFE mode enabled, and start the gRPC server using the SPIRE workload API for credentials
- **AND** the checker's SPIFFE ID SHALL match the identity assigned in the onboarding package.

#### Scenario: Graceful fallback to manual configuration
- **WHEN** no onboarding token is provided via CLI or environment
- **THEN** sysmon SHALL load configuration from the specified config file path using the existing `--config` flag behavior without attempting edge onboarding.

### Requirement: Rust edge onboarding crate provides reusable bootstrap logic
The project SHALL provide a Rust crate (`edge-onboarding`) that encapsulates edge onboarding logic for use by sysmon and other Rust-based checkers.

#### Scenario: Token parsing
- **WHEN** a valid `edgepkg-v1:<base64url>` token is provided
- **THEN** the crate SHALL parse and validate the token, extracting package ID, download token, and optional Core API URL.

#### Scenario: Package download from Core API
- **WHEN** `download_package()` is called with a valid token payload
- **THEN** the crate SHALL POST to `/api/admin/edge-packages/{id}/download?format=json` with the download token and return the package metadata, mTLS bundle, and/or SPIRE credentials.

#### Scenario: mTLS credential installation
- **WHEN** an mTLS bundle is provided in the package response
- **THEN** the crate SHALL write CA cert, client cert, and client key to the specified directory with appropriate file permissions (0600 for keys, 0644 for certs).

#### Scenario: Config generation
- **WHEN** onboarding succeeds
- **THEN** the crate SHALL generate a JSON config file compatible with the sysmon `Config` struct, including the security configuration derived from the onboarding package.

### Requirement: Sysmon checker persists onboarding state for restart resilience
The sysmon checker SHALL detect and reuse previously onboarded credentials on restart, avoiding redundant token downloads.

#### Scenario: Restart with existing credentials
- **GIVEN** sysmon was previously onboarded and credentials exist in the cert directory
- **WHEN** sysmon restarts without a new onboarding token
- **THEN** it SHALL detect the existing credentials and generated config, skip the onboarding download, and start using the persisted configuration.

#### Scenario: Re-onboarding with new token
- **GIVEN** sysmon was previously onboarded
- **WHEN** a new onboarding token is provided via CLI or environment
- **THEN** sysmon SHALL download fresh credentials, overwrite the existing ones, and start with the new configuration.

### Requirement: Deployment type detection for environment-specific behavior
The edge onboarding crate SHALL detect the deployment environment (Docker, Kubernetes, bare-metal) and adjust configuration paths and credential storage accordingly.

#### Scenario: Docker environment detection
- **WHEN** the `/.dockerenv` file exists or `container=docker` environment variable is set
- **THEN** the crate SHALL detect deployment type as Docker and use container-appropriate paths for credential storage.

#### Scenario: Kubernetes environment detection
- **WHEN** the `KUBERNETES_SERVICE_HOST` environment variable is set or `/var/run/secrets/kubernetes.io/serviceaccount/token` exists
- **THEN** the crate SHALL detect deployment type as Kubernetes and configure paths compatible with pod filesystem layouts.

#### Scenario: Bare-metal fallback
- **WHEN** neither Docker nor Kubernetes indicators are present
- **THEN** the crate SHALL assume bare-metal deployment and use standard Linux paths (e.g., `/var/lib/serviceradar/sysmon/`).
