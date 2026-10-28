## ADDED Requirements

This delta covers the full renewal roadmap. Phase 1 implements peer inventory
and expiry monitoring; `RenewCertificate`, `cert_renewal_error`, and
renewal-failure alerts remain pending in [tasks](../../tasks.md).

### Requirement: Agent Certificate Lifecycle Inventory and Alerting
The system SHALL persist each agent's active mTLS certificate metadata (`cert_serial`, `cert_fingerprint_sha256`, `cert_not_before`, `cert_expires_at`, `cert_renewed_at`, and `cert_renewal_error`) on `platform.ocsf_agents`, expose certificate expiry filtering in SRQL (`in:agents cert_expires_at:<duration>`), and emit platform alerts before certificate expiration and on renewal failure.

#### Scenario: Gateway records peer certificate expiry on Hello and renewal
- **GIVEN** an agent connects to `serviceradar-agent-gateway` and completes `Hello` or `RenewCertificate`
- **WHEN** the gateway processes the verified peer client certificate
- **THEN** the corresponding `ocsf_agents` record SHALL be updated with `cert_serial`, `cert_fingerprint_sha256`, `cert_not_before`, and `cert_expires_at`

#### Scenario: Querying expiring agents via SRQL
- **GIVEN** `ocsf_agents` contains agents with `cert_expires_at` within 5 days and agents with `cert_expires_at` 60 days in the future
- **WHEN** a client executes the SRQL query `in:agents cert_expires_at:<7d`
- **THEN** the query SHALL return only the agents whose `cert_expires_at` timestamp is less than 7 days from the current UTC time (including already-expired certificates)
- **AND** each returned agent object SHALL include `cert_expires_at`, `cert_serial_number`, and `cert_fingerprint_sha256`

#### Scenario: Alert emitted for approaching certificate expiry or renewal failure
- **GIVEN** an agent's `cert_expires_at` is within the expiry thresholds documented in [certificate operations](../../../../../docs/docs/edge-agent-onboarding.md#certificate-lifetime-and-expiry-alerts), or the agent's in-band certificate renewal fails
- **WHEN** the certificate expiry monitor or renewal handler evaluates the agent state
- **THEN** the platform SHALL emit an alert identifying the `agent_uid`, current `cert_expires_at` timestamp, and any `cert_renewal_error`
