## ADDED Requirements

### Requirement: In-Band Agent mTLS Certificate Renewal
Connected agents SHALL automatically renew their mTLS leaf certificate over the authenticated `AgentGatewayService.RenewCertificate` gRPC RPC at two-thirds (`2/3`) of the certificate's validity window without requiring SPIFFE/SPIRE or restarting the agent process.

#### Scenario: Scheduled renewal at two-thirds of certificate lifetime
- **GIVEN** an enrolled agent running with a valid mTLS leaf certificate whose elapsed lifetime has reached two-thirds (`2/3`) of `notAfter - notBefore`
- **WHEN** the agent's renewal loop runs
- **THEN** the agent SHALL generate a new private key and a signed PKCS#10 Certificate Signing Request (`csr_der`)
- **AND** the agent SHALL call `AgentGatewayService.RenewCertificate` over its active mTLS connection
- **AND** the gateway SHALL verify the signature over DER-encoded `CertificationRequestInfo` using the CSR's public key and supported signature algorithm, reject requests whose signatures cannot be verified, ignore any Subject or SAN fields in the CSR, and issue a new leaf certificate bound to the `component_id`, `partition_id`, and `component_type` extracted from the caller's verified mTLS peer certificate
- **AND** the agent SHALL atomically persist the renewed certificate and private key to `/etc/serviceradar/certs/` and hot-reload its in-memory TLS credentials (`GetClientCertificate` / `GetCertificate`) without restarting the process

#### Scenario: Crash during keypair persistence
- **GIVEN** an agent has received and validated a renewed certificate matching its staged private key
- **WHEN** it commits the renewed keypair
- **THEN** it SHALL write and fsync the combined recovery bundle, atomically rename it to `component-bundle.pem`, and fsync the containing directory before replacing either live keypair file
- **AND** it SHALL fsync the directory after replacing both live files and before hot reload
- **AND** if a crash leaves a mismatched pair, startup SHALL repair the pair from the published bundle before loading TLS credentials, using fsynced temporary files, atomic renames, and directory fsync while retaining the bundle so repair remains repeatable

#### Scenario: Renewal response lost before successor use
- **GIVEN** the gateway has issued a successor certificate but the agent has not received the renewal response
- **WHEN** connectivity returns more than five minutes later while the predecessor is still valid and not independently revoked
- **THEN** the agent SHALL be able to retry renewal with the predecessor
- **AND** the gateway SHALL NOT retire the predecessor solely because issuance occurred or a handoff timeout elapsed

#### Scenario: Predecessor certificate retirement after renewal
- **GIVEN** `serviceradar-agent-gateway` has issued a renewed certificate $C_{\text{new}}$ to replace an agent's current certificate $C_{\text{old}}$
- **WHEN** the agent reconnects and completes `Hello` presenting $C_{\text{new}}$
- **THEN** the gateway SHALL record $C_{\text{old}}$'s serial number and SHA-256 fingerprint in the durable revocation store with reason `superseded_by_renewal`
- **AND** any subsequent connection attempt presenting $C_{\text{old}}$ SHALL be rejected

### Requirement: Expired and Revoked Certificate Rejection and Diagnostics
The `serviceradar-agent-gateway` SHALL reject expired or revoked client certificates at the mTLS boundary with no expired-certificate renewal grace window, and both the Go agent and gateway SHALL emit explicit certificate-expiry diagnostics instead of generic timeout errors.

#### Scenario: Expired local certificate detected by agent
- **GIVEN** an agent whose local `/etc/serviceradar/certs/component.pem` has `notAfter` in the past
- **WHEN** the agent starts or attempts to connect to `serviceradar-agent-gateway`
- **THEN** the agent SHALL log an explicit error stating that the local mTLS client certificate has expired (including `notAfter` and certificate serial number) and instructing the operator to re-enroll the agent
- **AND** the failure SHALL NOT be reported solely as a generic `context deadline exceeded` error

#### Scenario: Revoked agent or NATS leaf certificate denied renewal and connection
- **GIVEN** an agent or edge NATS leaf certificate (or its `component_id`) has been added to `platform.revoked_component_certificates`
- **WHEN** the component attempts to connect or call `RenewCertificate` on any `serviceradar-agent-gateway` instance
- **THEN** the gateway SHALL reject the request with `revoked_certificate`
- **AND** the revocation decision SHALL persist across gateway restarts and replicas
