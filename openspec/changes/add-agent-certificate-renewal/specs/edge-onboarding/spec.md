## ADDED Requirements

### Requirement: Explicit Configurable Edge Certificate Lifetimes
The system SHALL enforce an explicit, configurable default validity period for edge component leaf certificates (using the bounds in `ServiceRadar.Edge.CertificateLifetimePolicy`) across both `ServiceRadar.Edge.OnboardingPackages` and `ServiceRadarAgentGateway.CertIssuer`, and SHALL NOT default onboarding package certificates to a `1`-day validity period.

#### Scenario: Onboarding package created without explicit validity option
- **GIVEN** an administrator or API client creates an edge onboarding package without specifying `cert_validity_days`
- **WHEN** the platform issues the component leaf certificate
- **THEN** the issued certificate SHALL have a validity period equal to the shared policy default
- **AND** the certificate SHALL NOT default to a `1`-day lifetime

#### Scenario: Deployment overrides the default certificate lifetime
- **GIVEN** a deployment sets `AGENT_CERT_VALIDITY_DAYS` (Helm `certs.agentValidityDays`) to an integer from `7` to `365`
- **WHEN** core, web-ng, or the agent-gateway issues an agent leaf certificate without an explicit `cert_validity_days`
- **THEN** the issued certificate SHALL expire that many days after issuance
- **AND** the agent-gateway SHALL NOT require long-TTL approval for a lifetime equal to that default

#### Scenario: Reject an invalid deployment default at boot
- **GIVEN** `AGENT_CERT_VALIDITY_DAYS` is set to a value that is not an integer from `7` to `365`
- **WHEN** core, web-ng, or the agent-gateway starts
- **THEN** startup SHALL fail with an error naming `AGENT_CERT_VALIDITY_DAYS` and the allowed range

#### Scenario: Deploy page requests and reports the certificate lifetime
- **GIVEN** an operator creates an agent package from the Web-NG package form
- **WHEN** the form opens
- **THEN** the certificate validity field SHALL be pre-filled with the deployment default
- **AND** values outside `7..365` SHALL be rejected without issuing a certificate
- **AND** after creation the page SHALL show the expiry read from the issued certificate's `notAfter`

#### Scenario: Reject sub-minimum leaf certificate validity in production
- **GIVEN** a production request to create an onboarding package with `cert_validity_days` less than `7`
- **WHEN** certificate issuance is requested without an explicit test-only override
- **THEN** the system SHALL reject the request with a certificate lifetime validation error

### Requirement: In-Place Agent Re-Enrollment for Expired Certificates
The system SHALL allow an administrator to issue an in-place re-enrollment package for an existing agent whose mTLS leaf certificate has expired, preserving the agent's `component_id` (`agent_uid`), `partition_id`, and assigned configuration while revoking the predecessor certificate.

#### Scenario: Re-enrolling an agent with an expired certificate
- **GIVEN** an existing registered agent `agent-01` in partition `default` whose leaf certificate has expired
- **WHEN** an administrator generates a re-enrollment token for `agent-01` and executes `serviceradar-cli enroll --token <token>` on the agent host
- **THEN** the system SHALL issue a new leaf certificate with CN `agent-01.default.serviceradar` and URI SAN `spiffe://serviceradar.local/agent/default/agent-01`
- **AND** the predecessor certificate serial number and SHA-256 fingerprint SHALL be recorded as revoked
- **AND** the agent SHALL reconnect under the existing `agent-01` inventory record without creating a duplicate agent entry
