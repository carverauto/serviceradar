# Change: Automatic Agent mTLS Certificate Renewal and Lifecycle Observability

## Why

This describes the pre-change motivation and full renewal roadmap. See
[tasks](tasks.md) for implemented scope and remaining work.

Edge agents enrolled via `ServiceRadarWebNG.Edge.OnboardingPackages` receive a static leaf X.509 certificate and private key written once to `/etc/serviceradar/certs/component.pem` and `/etc/serviceradar/certs/component-key.pem`, with zero rotation or renewal mechanism after enrollment. Compounding this gap, `ServiceRadar.Edge.OnboardingPackages.create_with_platform_cert/2` defaults `:cert_validity_days` to `1` while `ServiceRadarAgentGateway.CertIssuer` defaults to `365`, causing enrolled agents to receive 1-day leaf certificates unless callers explicitly override `:cert_validity_days`.

When an enrolled agent's leaf certificate expires:
- `serviceradar-agent-gateway` rejects the TLS handshake with `bad_certificate` / `certificate_expired`;
- the Go agent logs a generic `rpc error: code = DeadlineExceeded desc = context deadline exceeded` instead of identifying the local leaf certificate expiration;
- `ocsf_agents` and the Fleet UI have no visibility into per-agent certificate expiration (`notAfter`), serial number, or renewal status; and
- operators must manually generate a new onboarding token and re-enroll every expired host via SSH.

## What Changes

- **In-band mTLS Certificate Renewal (`AgentGatewayService.RenewCertificate`)**:
  - Add `RenewCertificate(CertificateRenewalRequest) returns (CertificateRenewalResponse)` to `monitoring.AgentGatewayService` over the existing mutually-authenticated gRPC session.
  - Require proof of possession of a freshly generated private key via a PKCS#10 Certificate Signing Request (`csr_der`) signed by the new key, while deriving `component_id`, `partition_id`, and `component_type` exclusively from the authenticated peer's current mTLS client certificate (`ServiceRadarAgentGateway.ComponentIdentityResolver`) -- never from untrusted CSR subject/SAN fields.
  - Agents automatically initiate renewal at two-thirds (`2/3`) of their leaf certificate's validity window (with jitter and exponential backoff on transient failures), write the new keypair and chain atomically to `/etc/serviceradar/certs/`, and hot-reload both client and server TLS credentials in memory (`tls.Config.GetClientCertificate` / `GetCertificate`) without restarting the agent process or dropping active checks.
  - Predecessor retirement follows [Decision 5](design.md#decision-5-interaction-with-leaf-and-component-revocation-5257).
- **Expired-Certificate Recovery Policy**:
  - Reject expired client certificates at the TLS handshake boundary and recheck authenticated peer validity against current gateway time immediately before signing every renewal, including retries over existing connections, with no unauthenticated or expired-cert renewal grace window (preventing an attacker who compromises a decommissioned host or backups after expiry from silently minting a fresh certificate).
  - Provide a single-command operator re-enrollment path (`serviceradar-cli enroll --token <token>` / `POST /api/admin/agents/:uid/reissue-enrollment-token`) that preserves the existing `component_id` (`agent_uid`) and replaces the expired certificate bundle in place without duplicating inventory records.
- **Explicit, Configurable Certificate Lifetimes**:
  - Replace the accidental short default with the shared lifetime policy; see [Decision 3](design.md#decision-3-explicit-configurable-certificate-lifetimes-fixing-the-1-day-default) for the implemented deployment override and package form.
- **Fleet & SRQL Certificate Visibility, Alerting, and Diagnostics**:
  - Persist peer certificate lifecycle metadata on `platform.ocsf_agents`; see [Decision 4](design.md#decision-4-visibility-srql-support-alerting-and-diagnostics) for implemented inventory and pending renewal status.
  - Expose `cert_expires_at` (`cert_not_after`), `cert_serial_number`, and `cert_fingerprint` in SRQL `in:agents` queries (supporting relative time comparisons such as `in:agents cert_expires_at:<7d` and ordering by `cert_expires_at`).
  - Surface certificate expiry badges, countdowns, and renewal errors in the Web-NG Agents Fleet and detail views.
  - Emit proactive platform alerts for approaching expiry and renewal failures, with agent-side local expiry diagnostics and gateway-side peer rejection diagnostics as defined in [Decision 4](design.md#decision-4-visibility-srql-support-alerting-and-diagnostics).
- **Unified Revocation Integration (`#5257`)**:
  - Back `ServiceRadarAgentGateway.AgentCertificateRevocation` with a durable CNPG revocation table (`platform.revoked_component_certificates`) synchronized across all `agent-gateway` nodes and the NATS leaf authentication boundary (`#5257`), ensuring revoked agents and edge NATS leaves cannot renew certificates or reconnect.
- **Zero SPIFFE/SPIRE Dependency**:
  - All issuance, identity binding, rotation, and revocation use ServiceRadar's internal X.509 CA (`ServiceRadarAgentGateway.CertIssuer` / platform CA) and standard X.509 CN + URI SANs (`spiffe://serviceradar.local/<component_type>/<partition_id>/<component_id>` as a static X.509 URI SAN convention only, with no SPIRE server, agent, workload API, or CRD dependency).

## Impact

- Affected specs:
  - `edge-onboarding`
  - `agent-connectivity`
  - `agent-registry`
- Affected code (implemented and planned):
  - `proto/monitoring.proto` (`RenewCertificate` RPC)
  - `elixir/serviceradar_agent_gateway/lib/serviceradar_agent_gateway/{agent_gateway_server.ex,cert_issuer.ex,agent_certificate_revocation.ex,component_identity_resolver.ex}`
  - `elixir/serviceradar_core/lib/serviceradar/edge/onboarding_packages.ex`
  - `elixir/serviceradar_core/lib/serviceradar/infrastructure/agent.ex` (plus CNPG migration for `ocsf_agents` certificate columns and `platform.revoked_component_certificates`)
  - `go/pkg/grpc/security.go` and `go/pkg/agent/` (renewal loop, CSR generation, atomic cert writer, `GetClientCertificate` hot reload, local expiry pre-check)
  - `rust/srql/src/query/agents.rs` and `rust/srql/src/schema.rs` (`cert_expires_at` filter and projection)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/live/agent_live/`
- Related issues:
  - `#6120` (Agent mTLS certificate renewal design)
  - `#5257` (Edge NATS leaf and component certificate revocation)
  - `#5413` (Removal of SPIFFE/SPIRE support)
