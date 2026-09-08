# edge-onboarding Specification

## Purpose
TBD - created by archiving change improve-edge-onboarding-ux. Update Purpose after archive.
## Requirements
### Requirement: Automatic Certificate Generation on Package Creation

When a tenant admin creates an edge onboarding package through the web UI, the system SHALL automatically generate all required certificates without any manual intervention.

The system SHALL:
1. Check for an existing tenant intermediate CA and generate one if not present
2. Generate a component certificate signed by the tenant CA
3. Include the encrypted certificate bundle in the onboarding package
4. Display certificate fingerprint and validity information after creation

#### Scenario: First package creation generates tenant CA

- **GIVEN** a tenant has no existing intermediate CA
- **WHEN** a tenant admin creates their first edge onboarding package
- **THEN** the system automatically generates a tenant intermediate CA
- **AND** generates a component certificate signed by the new CA
- **AND** the package includes the encrypted certificate bundle
- **AND** no CLI commands or manual steps are required

#### Scenario: Subsequent packages reuse tenant CA

- **GIVEN** a tenant already has an active intermediate CA
- **WHEN** a tenant admin creates an additional edge onboarding package
- **THEN** the system generates a new component certificate using the existing CA
- **AND** the package creation is faster (no CA generation overhead)

#### Scenario: Certificate information displayed after creation

- **GIVEN** a tenant admin has submitted the package creation form
- **WHEN** the package is successfully created
- **THEN** the system displays the certificate fingerprint
- **AND** shows the certificate validity period
- **AND** provides download options for the package bundle

### Requirement: Downloadable Installation Bundle

The system SHALL provide a downloadable bundle containing all files needed to deploy an edge component, eliminating the need for manual file assembly.

The bundle SHALL include:
1. Component certificate (PEM format)
2. Component private key (PEM format)
3. CA chain certificate (for trust verification)
4. Component configuration file
5. Platform-detecting installation script

#### Scenario: Download bundle as archive

- **GIVEN** a package has been successfully created
- **WHEN** the admin clicks "Download Bundle"
- **THEN** the system delivers a compressed archive file
- **AND** the archive contains certs/, config/, and install.sh
- **AND** all certificate files are in PEM format

#### Scenario: Bundle includes install script

- **GIVEN** a bundle is downloaded
- **WHEN** the admin inspects the bundle contents
- **THEN** the bundle contains an install.sh script
- **AND** the script detects available platforms (Docker, systemd)
- **AND** the script provides usage instructions if manual install is required

#### Scenario: Helm generates a unique onboarding signing key by default
- **GIVEN** the Helm chart is installed without an explicit onboarding signing key override
- **WHEN** the secret-generation hook runs
- **THEN** it SHALL generate a unique onboarding signing key for that install
- **AND** the chart SHALL NOT ship a fixed default onboarding signing key value

### Requirement: One-Liner Install Commands

The system SHALL display platform-specific one-liner install commands that the admin can copy and run on the target system.

#### Scenario: Docker install command displayed

- **GIVEN** a package has been successfully created
- **WHEN** the admin views the success modal
- **THEN** the system displays a Docker-based install command
- **AND** the command can be copied with one click
- **AND** the command includes the download token for authentication

#### Scenario: Copy command to clipboard

- **GIVEN** the success modal is displayed with install commands
- **WHEN** the admin clicks the copy button
- **THEN** the command is copied to the system clipboard
- **AND** a confirmation message is shown

#### Scenario: Rust onboarding preserves token-authenticated API URL
- **GIVEN** a Rust-based edge checker is given a structured onboarding token with an API URL
- **WHEN** an operator also passes `--host` or `CORE_API_URL`
- **THEN** the crate SHALL continue using the token-authenticated API URL
- **AND** operator input SHALL NOT replace it

### Requirement: Token Expiration Visibility

The system SHALL clearly display token expiration information to help admins understand the time window for deployment.

#### Scenario: Expiration countdown on package details

- **GIVEN** a package exists with a download token
- **WHEN** the admin views the package details
- **THEN** the system displays the expiration date/time
- **AND** if expiring within 24 hours, shows time remaining
- **AND** indicates if the token has already expired

### Requirement: mTLS CA file access is confined to an operator-configured directory
When issuing an edge onboarding package in mTLS mode, Core SHALL only read the CA certificate and private key from an operator-configured base directory (default: `/etc/serviceradar/certs`) and SHALL reject requests that attempt to reference paths outside that directory.

#### Scenario: Reject user-controlled CA path escape attempt
- **GIVEN** edge onboarding is enabled
- **WHEN** an admin issues an mTLS edge package with `metadata_json` that sets `ca_cert_path` (or `ca_key_path`) to a path outside the configured base directory
- **THEN** Core SHALL reject the request as invalid
- **AND** Core SHALL NOT attempt to read the referenced CA cert/key paths

#### Scenario: Allow default CA directory
- **GIVEN** edge onboarding is enabled
- **WHEN** an admin issues an mTLS edge package without overriding CA certificate/key paths
- **THEN** Core SHALL read CA material from the configured base directory and mint the mTLS bundle

### Requirement: Edge onboarding events are mirrored into OCSF
The system SHALL write an OCSF Event Log Activity entry when an edge onboarding lifecycle event is recorded so the Events UI can display onboarding activity.

#### Scenario: Onboarding package event appears in OCSF
- **GIVEN** an onboarding package is created or delivered
- **WHEN** the onboarding event is recorded
- **THEN** an `ocsf_events` row SHALL be inserted for the tenant
- **AND** the OCSF event SHALL include the package ID and event type

### Requirement: Package-managed onboarding does not distribute release trust anchors
Edge onboarding for package-managed agents SHALL NOT persist `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY` into `/etc/serviceradar/kv-overrides.env` or any other generic environment override file used by the packaged agent service.

#### Scenario: Agent onboarding bundle omits release key override
- **GIVEN** the deployment configures `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY` for control-plane release validation
- **WHEN** the system generates a package-managed agent onboarding bundle
- **THEN** the bundle SHALL NOT include `config/agent-env-overrides.env` content that sets `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY`
- **AND** package-managed agent trust anchors SHALL remain package-owned instead of bundle-provided

#### Scenario: Enrollment preserves unrelated overrides without writing release key state
- **GIVEN** a host already has unrelated entries in `/etc/serviceradar/kv-overrides.env`
- **WHEN** `serviceradar-cli enroll` installs a package-managed agent bundle generated after this hardening change
- **THEN** enrollment SHALL preserve unrelated existing override entries
- **AND** it SHALL NOT add or update `SERVICERADAR_AGENT_RELEASE_PUBLIC_KEY`

### Requirement: Edge Onboarding Admin Operations Require RBAC Permission
Edge onboarding administrative operations (list, show, event listing, create, revoke, delete) MUST be restricted to actors with permission `settings.edge.manage` (or an equivalent dedicated permission key for edge onboarding management).

#### Scenario: Unauthorized user cannot access Edge onboarding admin UI
- **GIVEN** a logged-in user without `settings.edge.manage`
- **WHEN** the user visits `/admin/edge-packages`
- **THEN** the system denies access (redirect or error)

#### Scenario: Unauthorized token cannot access Edge onboarding admin API
- **GIVEN** an authenticated principal without `settings.edge.manage`
- **WHEN** the client calls `GET /api/admin/edge-packages`
- **THEN** the system returns `403 Forbidden`

### Requirement: Edge Package Delivery Remains Token-Gated
Token-gated delivery endpoints MUST validate the download token and MUST NOT rely on admin authentication for authorization. Token-gated delivery endpoints MUST NOT expose administrative list/read/mutate operations.

#### Scenario: Invalid download token is rejected
- **GIVEN** a package delivery endpoint is called with an invalid download token
- **WHEN** the request is processed
- **THEN** the system returns `401 Unauthorized` (or an equivalent error)

### Requirement: Structured onboarding tokens are integrity protected
The system SHALL protect structured onboarding tokens against tampering before enrollment clients trust embedded metadata such as package identifier, download token, or Core API endpoint. Signed `edgepkg-v2` tokens SHALL be the primary structured format. Legacy unsigned `edgepkg-v1` tokens SHALL NOT be allowed to supply a trusted Core API endpoint.

#### Scenario: Client rejects a tampered structured token
- **GIVEN** a structured onboarding token has been modified after issuance
- **WHEN** `serviceradar-cli enroll` parses the token
- **THEN** the client rejects the token before attempting bundle download
- **AND** the client does not trust the embedded Core API endpoint

#### Scenario: Client accepts an intact structured token
- **GIVEN** a signed `edgepkg-v2` onboarding token was generated by the control plane and has not been modified
- **WHEN** `serviceradar-cli enroll` parses the token
- **THEN** the client accepts the token payload
- **AND** may use the embedded Core API endpoint for bundle download

#### Scenario: Legacy unsigned token requires a separately trusted Core API URL
- **GIVEN** an operator uses a legacy unsigned `edgepkg-v1` onboarding token
- **WHEN** `serviceradar-cli enroll` parses the token
- **THEN** the client does not trust any embedded Core API endpoint from that token
- **AND** enrollment requires a separately trusted Core API URL such as `--core-url`

### Requirement: Edge onboarding bundle download is secure by default
The system SHALL require certificate-validated HTTPS for remote onboarding bundle downloads. The enrollment CLI SHALL NOT offer an insecure transport bypass.

#### Scenario: Enrollment verifies TLS by default
- **GIVEN** an operator runs `serviceradar-cli enroll --token ...`
- **WHEN** the client downloads the onboarding bundle from a remote endpoint
- **THEN** TLS certificate verification is enabled by default
- **AND** the client does not provide an insecure mode that skips certificate verification

#### Scenario: Enrollment rejects non-HTTPS remote endpoints
- **GIVEN** a structured onboarding token or fallback CLI argument references a remote `http://` endpoint
- **WHEN** the client prepares the bundle download
- **THEN** the client rejects the endpoint as insecure
- **AND** bundle download does not begin

