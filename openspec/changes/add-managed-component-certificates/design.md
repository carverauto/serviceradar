# Managed component certificate lifecycle

## Existing behavior and reuse

- `go/pkg/agent/cert_renewal.go` renews the agent's own certificate via CSR at
  two-thirds of its lifetime, installs atomically, and reconnects its gateway.
- `AgentCertificateRevocation` checks fingerprints/component identities but its
  ETS state is neither durable nor shared across gateway replicas.
- `NatsLeafCertificateIssuer` issues upstream client and local server certificates;
  the edge-site UI offers configuration regeneration and expiry information.
- `DirectLeafIdentityIssuer` provides assignment-scoped identities and a useful
  binding pattern, but revocation currently targets a live session's gateway.
- `ProvisionCollectorWorker` requires configured NATS account signing material
  and provisions JWT user credentials; it does not issue collector mTLS material.
- `serviceradar-cli nats account status` inspects readiness. It does not create the
  deployment account. The leaf mTLS path can work while collector JWT setup fails.

## Initial service catalog

The CLI maps syslog/flowgger and OTEL to `serviceradar-log-collector`, NetFlow
and sFlow to `serviceradar-flow-collector`, SNMP traps to `serviceradar-trapd`,
and BMP to `serviceradar-bmp-collector`.
NATS leaf server management is a separate adapter. Each managed service instance
has a distinct identity. Pipelines bundled in one fixed systemd service share
that service identity; a second conflicting component for the same host and
service is rejected. Enrollment preserves unrelated pipeline configuration.
The collector resource also names `falcosidekick`, but the CLI has no supported
host package mapping for it; that must remain explicit rather than being counted
as a working adapter. Per-service reload behavior still needs executable proof.

## Decisions

1. **One lifecycle authority, distinct component identities.** Reuse the deployment
   CA and gateway issuance path. Keep issuer keys on the trusted side. Host agents
   generate component private keys locally and submit CSRs for server-authorized
   assignments. An agent must not choose an arbitrary component identity or mint
   certificates for another host. Separate each collector identity from its host
   agent and each leaf's client identity from its server identity.
2. **Managed service adapters.** Reuse the agent renewal scheduler and crash-safe
   certificate writer. A registered adapter declares certificate paths, ownership,
   validation, and supported reload/restart behavior for NATS, log collectors,
   flow collectors, trap receivers, and applicable native add-ons. Enumerate the
   supported service catalog before implementation; unsupported services fail
   explicitly rather than falling back to shared keys or unchecked shell commands.
3. **Durable, receiver-enforced revocation.** Complete the CNPG-backed authority
   already designed for #5257. Revoking one issued certificate targets its issuer
   and fingerprint; revoking a component also blocks future issuance until an
   explicit re-enrollment. Do not rely on serial numbers alone or on the remote
   agent deleting files. Core, gateway replicas, and NATS enforcement points must
   reconcile persisted state after startup and missed notifications.
4. **Protocol choice requires a compatibility proof.** CRLs and OCSP are standard
   X.509 status mechanisms. NATS also supports peer OCSP checks and authorization
   integration, but a setting's presence is not proof of complete revocation.
   First prove the deployed NATS version can reject one leaf and one collector,
   disconnect their existing sessions, and preserve another site's sessions.
   Select the supported adapter in this design before implementation. Include
   server-certificate rejection by Go, Rust, and Erlang clients. Do not silently
   substitute JWT revocation for certificate revocation.
5. **Explicit NATS deployment mode.** CLI preflight distinguishes static mTLS from
   operator/JWT mode. Static mTLS onboarding must not require a nonexistent account
   seed. JWT deployments need a configured, server-owned account signer/resolver;
   component enrollment creates scoped user access within that existing account.
   Any deployment-account bootstrap is a separate privileged setup operation,
   idempotent and visible, not an implicit side effect on an edge host.
6. **Plain PKIX for managed components.** Managed leaf and collector
   certificates carry DNS and IP names only. Hub admission and revocation use
   the stored fingerprint. NATS 2.14 leaf observation uses an authenticated
   CONNZ listing of the presented certificate (`kind` Leafnode, `cert_sha256`).
   LEAFZ does not carry the certificate, and a CONNZ lookup by connection id
   omits leaves. `KICK` closes the leaf. The chart leaves callout disabled
   and does not open a leaf listener that would fall through to the global
   account. SPIRE is not part of this path.
7. **Honest operational state.** UI shows desired revocation and enforcement
   acknowledgements separately, including failures and offline enforcement points.
   Proposed online enforcement bound: 60 seconds from accepted revoke to rejection
   of reconnect/renewal and termination of affected sessions. Validate that bound
   before beta acceptance. Disconnected edges cannot learn a new revocation
   instantly. During a WAN outage, local collectors continue ingesting to their
   enrolled local leaf using the last verified policy, with stale enforcement
   reported explicitly. This exception is bound to that local leaf identity and
   endpoint; it does not apply to hub, core, or gateway authorization, certificate
   expiry, or CA/hostname verification. A fresh policy applies known revocations
   immediately, and the hub checks current policy when an edge reconnects.
   A compromised/offline agent cannot prevent hub-side revocation. Existing
   telemetry remains stored and queryable.
7. **Rotation differs from revocation.** Rotation installs and confirms the successor
   before retiring the predecessor, retaining the existing lost-response recovery
   contract. Emergency revocation does not wait for successor installation. A
   revoked component cannot use automatic renewal to escape the block. Revoking a
   host offers an explicit cascade to its managed identities; component revocation
   leaves unrelated identities usable.

## Scope and compatibility

No SPIRE dependency and no new multitenancy model. Deployment infrastructure
credentials remain distinct from monitored-device/integration credentials.
Core and gateway certificates join the inventory and revocation policy; their
existing deployment mechanism may install replacements. Requiring an agent on
edge hosts does not require a new agent in every Kubernetes control-plane pod.

## Rollout and acceptance

Start with one managed NATS leaf and one log collector, then cover every registered
edge collector adapter. Keep an unaffected peer as the isolation control. Exercise
rotation, emergency revoke, renewal denial, process restart, replica failover,
offline reconciliation, and replacement enrollment. Verify actual TLS/authorization
rejection and disconnected sessions, not UI status alone. Do not revoke live
shared infrastructure identities as an acceptance shortcut.

## Endpoint advertisement

Collector-facing leaf URLs and upstream hub URLs are separate configuration.
Enrollment stores an explicit advertised leaf URL, or infers it only when the
host has one unambiguous usable address. A loopback address is not advertised to
remote collectors. Helm and Compose expose the hub URL explicitly; Kubernetes
may route its TCP leaf listener through an existing gateway or a dedicated load
balancer. Private DNS and routed private addresses are sufficient for private
deployments. Every advertised TLS hostname must be present in the receiver's
certificate before clients switch to it.
