## ADDED Requirements

### Requirement: Agent Certificate Lifecycle Inventory and Alerting
The system SHALL persist each agent's active mTLS certificate metadata (`cert_serial_number`, `cert_fingerprint_sha256`, `cert_not_before`, `cert_not_after`, `cert_last_renewed_at`, and `cert_renewal_error`) on `platform.ocsf_agents`, expose certificate expiry filtering in SRQL (`in:agents cert_expires_at:<duration>`), and emit platform alerts before certificate expiration and on renewal failure.

#### Scenario: Gateway records peer certificate expiry on Hello and renewal
- **GIVEN** an agent connects to `serviceradar-agent-gateway` and completes `Hello` or `RenewCertificate`
- **WHEN** the gateway processes the verified peer client certificate
- **THEN** the corresponding `ocsf_agents` record SHALL be updated with `cert_serial_number`, `cert_fingerprint_sha256`, `cert_not_before`, and `cert_not_after`

#### Scenario: Querying expiring agents via SRQL
- **GIVEN** `ocsf_agents` contains agents with `cert_not_after` within 5 days and agents with `cert_not_after` 60 days in the future
- **WHEN** a client executes the SRQL query `in:agents cert_expires_at:<7d`
- **THEN** the query SHALL return only the agents whose `cert_not_after` timestamp is less than 7 days from the current UTC time (including already-expired certificates)
- **AND** each returned agent object SHALL include `cert_expires_at`, `cert_serial_number`, and `cert_fingerprint_sha256`

#### Scenario: Alert emitted for approaching certificate expiry or renewal failure
- **GIVEN** an agent's `cert_not_after` is within the warning (`<14d`) or critical (`<7d`) threshold, or the agent's in-band certificate renewal fails
- **WHEN** the certificate expiry monitor or renewal handler evaluates the agent state
- **THEN** the platform SHALL emit an alert identifying the `agent_uid`, current `cert_not_after` timestamp, and any `cert_renewal_error`
