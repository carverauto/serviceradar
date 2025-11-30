## ADDED Requirements
### Requirement: mTLS-only sysmon-vm onboarding for Docker Compose
The system SHALL provide a token-based mTLS onboarding flow for sysmon-vm checkers targeting a Docker Compose deployment, without requiring SPIRE on the edge host.

#### Scenario: Token-driven bundle download and install
- **WHEN** an operator issues an edge onboarding token for `checker:sysmon-vm` and runs `serviceradar-sysmon-vm --mtls --token <token> --host <compose-core-or-bootstrap> --poller-endpoint 192.168.1.218:<checker-port>` on a darwin/arm64 or Linux edge host
- **THEN** sysmon-vm SHALL download an onboarding bundle (CA, client cert/key, expected endpoints) over HTTPS from Core (or the enrollment handler), install it to `/etc/serviceradar/certs` (or the configured writable path), and start with mTLS using the provided poller endpoint
- **AND** the poller/core in the Compose stack SHALL accept the sysmon-vm connection because the client certificate chains to the Compose CA.

#### Scenario: Offline or pre-fetched bundle use
- **WHEN** an operator supplies a pre-fetched bundle via `--bundle /path/to/bundle.tar.gz` alongside `--mtls`
- **THEN** sysmon-vm SHALL validate the bundle integrity (including CA/client cert/key presence and expiry) and proceed with the same mTLS startup without contacting Core.

### Requirement: Docker Compose CA issues edge enrollment bundles
The Docker Compose deployment SHALL generate or accept a TLS CA, issue leaf certificates for internal services, and issue per-edge sysmon-vm client certificates via onboarding tokens or bundle requests.

#### Scenario: Compose CA generation and reuse
- **WHEN** the Compose stack starts without a pre-provided CA
- **THEN** it SHALL generate a CA once, reuse it for core/poller/agent/checker service certs, and expose an enrollment path that issues per-edge sysmon-vm bundles signed by that CA, so edge nodes can join with mTLS without SPIRE.

#### Scenario: Controlled bundle issuance
- **WHEN** an admin requests an mTLS onboarding bundle for sysmon-vm via Core (edge package) or a Compose enrollment endpoint
- **THEN** the system SHALL enforce token validity/TTL, bind the client cert to the requested checker identity, include the CA and poller/core endpoints, and record issuance so operators can rotate or revoke the bundle if needed.
