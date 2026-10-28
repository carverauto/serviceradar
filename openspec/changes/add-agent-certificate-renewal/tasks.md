# Implementation Tasks: Automatic Agent mTLS Certificate Renewal

## 1. Protobuf & Certificate Lifetime Policy
- [x] 1.1 Add `RenewCertificate(CertificateRenewalRequest) returns (CertificateRenewalResponse)` to `monitoring.AgentGatewayService` in `proto/monitoring.proto`, then regenerate Go and Elixir protobuf bindings.
- [x] 1.2 Create `ServiceRadar.Edge.CertificateLifetimePolicy` in `elixir/serviceradar_core` defining the shared leaf certificate validity bounds, plus renewal scheduling constants.
- [x] 1.3 Fix `ServiceRadar.Edge.OnboardingPackages.create_with_platform_cert/2` and `ServiceRadarWebNG.Edge.OnboardingPackages` to use `CertificateLifetimePolicy.default_validity_days()` (`90` days) instead of `1` day.

## 2. CNPG Migrations, Ash Resources & Durable Revocation (`#5257`)
- [x] 2.1a Add a CNPG migration adding `cert_not_before`, `cert_expires_at`, `cert_serial`, `cert_fingerprint_sha256`, and `cert_renewed_at` to `platform.ocsf_agents` (with an index on `cert_expires_at`).
- [ ] 2.1b Add a CNPG migration creating `platform.revoked_component_certificates` (deferred to `#5257`; Phase 2 renewal tracks pending predecessor-successor handoffs in `ServiceRadarAgentGateway.AgentCertificateRevocation` and retires the predecessor upon authenticated `Hello` with the successor without coupling renewal to the NATS leaf CNPG revocation table).
- [ ] 2.1c Add `cert_renewal_error` when renewal status reporting is implemented.
- [x] 2.2 Update `ServiceRadar.Infrastructure.Agent` (`elixir/serviceradar_core/lib/serviceradar/infrastructure/agent.ex`) with the certificate lifecycle attributes and update actions.
- [ ] 2.3 Back `ServiceRadarAgentGateway.AgentCertificateRevocation` with `platform.revoked_component_certificates` and cluster-wide PubSub synchronization (`serviceradar:cert_revocations`), enforcing revocation checks in `ComponentIdentityResolver` and NATS leaf authentication (`#5257`, deferred independently of Phase 2 agent certificate renewal).

## 3. Agent Gateway CSR Issuance & Renewal Handler
- [x] 3.1 Implement `ServiceRadarAgentGateway.CertIssuer.issue_from_csr/5` to verify the PKCS#10 CSR signature over DER-encoded `CertificationRequestInfo` using the CSR's public key and supported signature algorithm (`:public_key.verify/4` or equivalent), and enforce key strength while deriving `component_id`, `partition_id`, and `component_type` strictly from the authenticated peer identity.
- [x] 3.2 Implement `ServiceRadarAgentGateway.AgentGatewayServer.renew_certificate/2`, enforcing `NotBefore <= now < NotAfter` against current gateway UTC time immediately before signing every attempt (including retries on existing TLS connections) and rejecting invalid peers without issuance, deriving active certificate metadata from the authenticated TLS peer, emitting `:agent_certificate_renew` audit events, recording predecessor-successor handoffs in `ServiceRadarAgentGateway.AgentCertificateRevocation`, and retiring the predecessor only after authenticated `Hello` with the successor (never on an issuance timeout) (`reason = "superseded_by_renewal"`).
- [x] 3.3 Record peer certificate `notBefore`, `notAfter`, `serial_number`, and `fingerprint` on `ServiceRadar.Infrastructure.Agent` during `Hello` and `ControlStream` establishment.
- [x] 3.4 Enhance gateway TLS handshake failure logging to report peer certificate CN, serial number, `notAfter`, and explicit rejection reason (`certificate_expired`, `certificate_revoked`, `unknown_ca`).

## 4. Go Agent Renewal Loop, Atomic Persistence & Hot Reload
- [x] 4.1 Update `go/pkg/grpc/security.go` (`MTLSProvider`) to serve client and server certificates dynamically via `tls.Config.GetClientCertificate` and `tls.Config.GetCertificate` backed by an `atomic.Pointer[tls.Certificate]`, plus a local pre-dial certificate expiry check that logs `"local mTLS client certificate expired (notAfter=..., serial=...); re-enroll required"` instead of generic deadline errors.
- [x] 4.2 Implement the agent certificate renewal manager in `go/pkg/agent/` that triggers at `2/3` of certificate lifetime (with jitter and exponential backoff, checking local expiry before each attempt and stopping with a re-enrollment diagnostic at `now >= NotAfter`), generates a fresh private key and PKCS#10 CSR, calls `RenewCertificate`, publishes and directory-fsyncs `component-bundle.pem` before replacing either `component-key.pem` or `component.pem`, then directory-fsyncs the completed pair (with repeatable startup self-heal from the retained bundle), hot-reloads `MTLSProvider`, and reconnects the gateway stream.
- [x] 4.3 Add unit and integration tests for `2/3` lifetime scheduling, CSR proof-of-possession verification, atomic disk write recovery, hot reload without process restart, and explicit expired-certificate error reporting.

## 5. SRQL, Alerting, Fleet UI & In-Place Re-Enrollment
- [x] 5.1 Extend `rust/srql/src/query/agents.rs` and `rust/srql/src/schema.rs` to project and filter `cert_expires_at` (`cert_not_after`), `cert_serial_number`, and `cert_fingerprint` (including relative time queries like `in:agents cert_expires_at:<7d`).
- [x] 5.2a Add `ServiceRadar.Infrastructure.AgentCertExpiryMonitor` for expiry alerts; thresholds and resolution behavior are documented in [certificate operations](../../../docs/docs/edge-agent-onboarding.md#certificate-lifetime-and-expiry-alerts).
- [ ] 5.2b Add renewal-failure alerts when the renewal handler is implemented.
- [ ] 5.3 Update Web-NG Agents LiveView (`elixir/web-ng/lib/serviceradar_web_ng_web/live/agent_live/`) to display certificate expiration status, serial/fingerprint metadata, renewal errors, and a single-click **Re-enroll Agent** action that issues an in-place onboarding token preserving the existing `agent_uid`.
