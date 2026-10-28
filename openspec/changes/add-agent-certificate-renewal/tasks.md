# Implementation Tasks: Automatic Agent mTLS Certificate Renewal

## 1. Protobuf & Certificate Lifetime Policy
- [ ] 1.1 Add `RenewCertificate(CertificateRenewalRequest) returns (CertificateRenewalResponse)` to `monitoring.AgentGatewayService` in `proto/monitoring.proto`, then regenerate Go and Elixir protobuf bindings.
- [ ] 1.2 Create `ServiceRadar.Edge.CertificateLifetimePolicy` in `elixir/serviceradar_core` defining default (`90` days), minimum (`7` days), and maximum (`825` days) leaf certificate validity and the `2/3` renewal threshold.
- [ ] 1.3 Fix `ServiceRadar.Edge.OnboardingPackages.create_with_platform_cert/2` and `ServiceRadarWebNG.Edge.OnboardingPackages` to use `CertificateLifetimePolicy.default_validity_days()` (`90` days) instead of `1` day.

## 2. CNPG Migrations, Ash Resources & Durable Revocation (`#5257`)
- [ ] 2.1 Add a CNPG migration adding `cert_serial_number`, `cert_fingerprint_sha256`, `cert_not_before`, `cert_not_after`, `cert_last_renewed_at`, and `cert_renewal_error` to `platform.ocsf_agents` (with an index on `cert_not_after`) and creating `platform.revoked_component_certificates`.
- [ ] 2.2 Update `ServiceRadar.Infrastructure.Agent` (`elixir/serviceradar_core/lib/serviceradar/infrastructure/agent.ex`) with the certificate lifecycle attributes and update actions.
- [ ] 2.3 Back `ServiceRadarAgentGateway.AgentCertificateRevocation` with `platform.revoked_component_certificates` and cluster-wide PubSub synchronization (`serviceradar:cert_revocations`), enforcing revocation checks in `ComponentIdentityResolver` and NATS leaf authentication (`#5257`).

## 3. Agent Gateway CSR Issuance & Renewal Handler
- [ ] 3.1 Implement `ServiceRadarAgentGateway.CertIssuer.issue_from_csr/5` to verify the PKCS#10 CSR signature and key strength while deriving `component_id`, `partition_id`, and `component_type` strictly from the authenticated peer identity.
- [ ] 3.2 Implement `ServiceRadarAgentGateway.AgentGatewayServer.renew_certificate/2`, deriving active certificate metadata from the authenticated TLS peer, emitting `:agent_certificate_renew` audit events, durably recording predecessor-successor relationships, and retiring the predecessor only after authenticated `Hello` with the successor (never on an issuance timeout) (`reason = "superseded_by_renewal"`).
- [ ] 3.3 Record peer certificate `notBefore`, `notAfter`, `serial_number`, and `fingerprint` on `ServiceRadar.Infrastructure.Agent` during `Hello` and `ControlStream` establishment.
- [ ] 3.4 Enhance gateway TLS handshake failure logging to report peer certificate CN, serial number, `notAfter`, and explicit rejection reason (`certificate_expired`, `certificate_revoked`, `unknown_ca`).

## 4. Go Agent Renewal Loop, Atomic Persistence & Hot Reload
- [ ] 4.1 Update `go/pkg/grpc/security.go` (`MTLSProvider`) to serve client and server certificates dynamically via `tls.Config.GetClientCertificate` and `tls.Config.GetCertificate` backed by an `atomic.Pointer[tls.Certificate]`, plus a local pre-dial certificate expiry check that logs `"local mTLS client certificate expired (notAfter=..., serial=...); re-enroll required"` instead of generic deadline errors.
- [ ] 4.2 Implement the agent certificate renewal manager in `go/pkg/agent/` that triggers at `2/3` of certificate lifetime (with jitter and exponential backoff), generates a fresh private key and PKCS#10 CSR, calls `RenewCertificate`, publishes and directory-fsyncs `component-bundle.pem` before replacing either `component-key.pem` or `component.pem`, then directory-fsyncs the completed pair (with repeatable startup self-heal from the retained bundle), hot-reloads `MTLSProvider`, and reconnects the gateway stream.
- [ ] 4.3 Add unit and integration tests for `2/3` lifetime scheduling, CSR proof-of-possession verification, atomic disk write recovery, hot reload without process restart, and explicit expired-certificate error reporting.

## 5. SRQL, Alerting, Fleet UI & In-Place Re-Enrollment
- [ ] 5.1 Extend `rust/srql/src/query/agents.rs` and `rust/srql/src/schema.rs` to project and filter `cert_expires_at` (`cert_not_after`), `cert_serial_number`, and `cert_fingerprint` (including relative time queries like `in:agents cert_expires_at:<7d`).
- [ ] 5.2 Add `ServiceRadar.Infrastructure.AgentCertExpiryMonitor` to emit warning (`<14d`) and critical (`<7d` or expired) platform alerts as well as renewal-failure alerts.
- [ ] 5.3 Update Web-NG Agents LiveView (`elixir/web-ng/lib/serviceradar_web_ng_web/live/agent_live/`) to display certificate expiration status, serial/fingerprint metadata, renewal errors, and a single-click **Re-enroll Agent** action that issues an in-place onboarding token preserving the existing `agent_uid`.
