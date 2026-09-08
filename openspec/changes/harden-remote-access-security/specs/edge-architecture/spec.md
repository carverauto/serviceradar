## ADDED Requirements

### Requirement: Remote-Access Adapter Security Review Gate
Every remote-access protocol adapter (SSH, RDP/desktop, file-transfer, recording, application/TCP, database, Kubernetes, MCP, and future protocols) SHALL pass a documented security review covering authentication/authorization, credential custody (in-memory, at-rest, in-transit), input handling, transport/protocol hardening, data lifecycle, failure modes, dependency licensing, and browser-side surface before it is enabled by default in any environment.

#### Scenario: New adapter requires review record
- **WHEN** a new remote-access protocol adapter is proposed
- **THEN** the proposal MUST include a threat-model section and a dependency/license scan
- **AND** the adapter MUST be feature-flagged off until the review is signed off

#### Scenario: Existing adapter changes require delta review
- **WHEN** an adapter is materially extended (new redirection channel, new credential mode, new transport, new browser path)
- **THEN** the change MUST update the adapter's threat-model record and re-run the dependency/license scan

### Requirement: Credential Custody and Zeroisation
Remote-access components SHALL minimise credential residency in memory, at rest, and in audit trails. In-memory credentials MUST be zeroised on session end. Static long-lived credential references MUST NOT be used; credential references handed to agents or browsers MUST be HMAC-signed, time-bound (sub-minute TTL), and replay-rejecting. Audit trails MUST NOT capture credential-bearing inputs, secret refs, attach-ticket plaintexts, or grant metadata.

#### Scenario: In-memory secret zeroisation
- **WHEN** a session terminates or a credential grant is dropped
- **THEN** the structures holding password, secret-ref, CA bundle, and Kerberos ticket material MUST be wiped (Rust `Zeroize` / `Drop`; Elixir process-state purge)
- **AND** subsequent allocations MUST NOT be able to read residual bytes

#### Scenario: Credential reference replay rejected
- **WHEN** a credential reference handed to an agent has expired or been used once already (per protocol)
- **THEN** the reference dereferencing endpoint MUST refuse the lookup and emit an audit event

#### Scenario: Audit row free of sensitive inputs
- **WHEN** an audit / PaperTrail row is written for a remote-access action
- **THEN** the row MUST NOT include `credential_rule_id`, `approval_id`, `metadata` carrying secrets, `attach_ticket_hash` plaintext, or any `*_credential` / `*_secret` field
- **AND** field-level exclusion MUST be configured at the resource (not relied on at the call site)

### Requirement: Bastion Logging Confidentiality
The remote-access bastion's logging, tracing, and telemetry pipelines SHALL NOT emit RPC payload bodies, frame contents, credential references, or session secrets at any default log level. Per-method metadata (method name, duration, status, actor identifier) is permitted; payload bodies are not.

#### Scenario: gRPC interceptor body redaction
- **WHEN** a gRPC method is invoked on the agent-gateway or bastion
- **THEN** any interceptor emitting log entries MUST emit only `{method, duration, status, actor}` and MUST NOT serialise the request or response body

#### Scenario: Error path redaction
- **WHEN** an internal error occurs while handling agent or operator traffic
- **THEN** the error returned to the operator (terminal, browser, structured response) MUST be a generic message; full error detail MUST be logged server-side with audit context only

### Requirement: Authenticated Frame Routing
Inter-component frames carrying control or media for a remote-access session (broker frames, desktop-media frames, control-stream messages) SHALL be cryptographically bound to the originating component identity and the session they belong to. String-equality comparison of identifiers MUST NOT be the sole authorisation check.

#### Scenario: Forged session/agent id rejected at broker
- **WHEN** a broker receives a frame whose `(session_id, agent_id)` pair is correct but whose per-frame HMAC (over `session_id, agent_id, seq, payload_hash`) is invalid
- **THEN** the broker MUST reject the frame, emit an audit event, and continue routing other traffic

#### Scenario: Cross-agent media injection refused
- **WHEN** a desktop-media frame's declared `agent_id` or `partition_id` does not match the session's bound agent/partition
- **THEN** the media server MUST refuse the frame and emit an audit event

#### Scenario: Control stream re-validates per message
- **WHEN** a control-stream session receives a message after `register/1`
- **THEN** the handler MUST verify the inbound message's caller certificate matches the registered cert/agent_id before acting

### Requirement: Single-Use Session Attach Tickets
Session attach tickets SHALL be single-use within their TTL. The first successful consume MUST be atomic with the session's state transition; any subsequent consume of the same ticket MUST be refused with an audit event.

#### Scenario: Replay within TTL rejected
- **WHEN** a stolen but unexpired attach ticket is presented a second time
- **THEN** the consume action MUST return `invalid_or_expired` and emit an audit event identifying the replay attempt

### Requirement: Per-Action Authorization and Post-Authentication Re-Check
Authorisation for remote-access actions SHALL be enforced per-action — not only at mount or attach. Long-lived UI surfaces (LiveView event handlers, WebSocket message handlers, streaming HTTP responses) MUST re-check the actor's permission against the action before each effectful operation, OR subscribe to a permission-revocation channel that immediately terminates affected sessions.

#### Scenario: LiveView event without permission denied
- **WHEN** an authenticated operator triggers a mutating handle_event on a remote-access settings LiveView without holding the action's permission
- **THEN** the event MUST be refused and the audit event recorded

#### Scenario: Revocation mid-stream closes WebSocket
- **WHEN** an operator's permission to use a target is revoked while a remote-access WebSocket is open
- **THEN** the bastion MUST close the affected socket within seconds and notify the operator

### Requirement: Recording Integrity and Lifecycle Custody
Session recordings SHALL be append-only, hash-chained, and tamper-evident. Manifest finalisation MUST be idempotent and bind cryptographically to the event list. Recording deletion MUST be RBAC-gated, audited, and use a soft-delete + grace-period pattern. Storage-tier infrastructure identifiers (bucket names, object keys, backend type) MUST NOT be returned to clients.

#### Scenario: Manifest hash binds events
- **WHEN** a recording is finalised
- **THEN** the manifest's signature MUST cover the manifest contents AND a canonical digest of the event list
- **AND** any post-seal event with a sequence greater than the sealed `event_count` MUST be refused

#### Scenario: Double finalize prevented
- **WHEN** the broker's terminate path is reached after `handle_cast(:close)` already finalised
- **THEN** the second finalisation attempt MUST be a no-op and MUST NOT rewrite the sealed manifest

#### Scenario: Recording delete is RBAC-gated and audited
- **WHEN** a recording deletion is requested
- **THEN** the action MUST require an explicit `recording.delete` permission, set a tombstone with `{deleted_at, actor, reason}`, emit an audit event, and defer hard-delete until the retention grace period elapses

#### Scenario: Infrastructure paths not leaked
- **WHEN** the recording controller or LiveView serialises a recording for the client
- **THEN** `storage_backend`, `storage_bucket`, and `object_key` MUST NOT appear in the response

### Requirement: Recording Access Scoping
Read access to a recording or its events SHALL be scoped to the actor's permission for *that specific recording's* session and target. Holding a protocol-wide permission (e.g. `remote-access.ssh.open`) MUST NOT grant read access to recordings the actor was not a party to, unless an explicit broad-view permission is held.

#### Scenario: Cross-session recording read denied
- **WHEN** an operator who was not the session actor (and lacks `recordings.view_all`) attempts to read or export a recording
- **THEN** the request MUST be refused with a 403-equivalent and audited

#### Scenario: Export requires view permission
- **WHEN** a recording export is requested
- **THEN** the actor MUST hold both `recordings.export` AND the recording's read permission; export of recordings in `:active` / `:pending` status MUST be refused

### Requirement: Approval Workflow Integrity
Access-request approvals SHALL prohibit self-approval and use atomic state transitions. The approver's identity MUST differ from the requester's identity unless the request explicitly enables self-approval and that exception is itself audited.

#### Scenario: Self-approval forbidden by default
- **WHEN** the requester of an access request attempts to approve their own request without the `allow_self_approval` exception
- **THEN** the approve action MUST be forbidden by the resource policy

#### Scenario: Approval bind is atomic
- **WHEN** two concurrent attach attempts reference the same approval
- **THEN** only one bind MUST succeed; the loser MUST receive a deterministic failure and MUST NOT produce side effects (session creation, audit row) past the failed point

### Requirement: Desktop Adapter Redirection Default-Off
Desktop / RDP adapters SHALL ship with all device-redirection channels disabled by default. Enabling any redirection (clipboard, drives, printers, audio, smart-card, USB, file-copy) MUST require both an RBAC permission for the actor and a per-target policy opt-in. Browser-side equivalents (clipboard API, display-capture, screen-share) MUST also be denied unless the same gates are satisfied.

#### Scenario: Default-off enforced at adapter and policy layers
- **WHEN** a new desktop target is created with no explicit redirection policy
- **THEN** clipboard, drives, printers, audio, smart-card, USB, and file-copy redirection MUST all be off
- **AND** the connector MUST refuse to negotiate any redirection channel the target policy doesn't explicitly enable

#### Scenario: Browser surface mirrors backend policy
- **WHEN** an operator opens a desktop session in the browser
- **THEN** the served response MUST set Content-Security-Policy + Permissions-Policy denying clipboard-read, clipboard-write, display-capture, camera, microphone unless the target policy explicitly enables that surface

### Requirement: Agent Identity Lifecycle
Agent mTLS certificates SHALL be short-lived, revocable, and partition-bound at issuance. Default certificate TTL MUST be measured in days, not months. A revocation mechanism (in-memory denylist at minimum) MUST exist so a compromised agent can be excluded before TTL expiry. The certificate's partition / tenant binding MUST be derived from the authenticated provisioning context, not from caller-supplied request fields.

#### Scenario: Issuance requires partition authorisation
- **WHEN** a provisioning action requests issuance of an agent certificate for a partition
- **THEN** the issuer MUST verify the requesting actor is authorised for that specific partition before signing
- **AND** the resulting certificate's partition extension MUST be set from the authoritative actor context, not echoed from the request body

#### Scenario: Revocation excludes a stolen cert before expiry
- **WHEN** an operator marks an agent certificate as compromised via the admin endpoint
- **THEN** subsequent connections presenting that certificate MUST be refused by the gateway, even while the cert is still within its TTL

#### Scenario: Short TTL by default
- **WHEN** an agent certificate is issued without an explicit `validity_days` override
- **THEN** the default TTL MUST be at most a few days; any longer TTL MUST require an explicit override flag and an audit event recording the override

### Requirement: Bootstrap Token Lifecycle
Bootstrap / onboarding tokens SHALL be single-use, partition-bound in the signed payload, and time-limited. Server-side enforcement MUST refuse a second consume of the same token regardless of TTL.

#### Scenario: Token consumed once
- **WHEN** a download / onboarding token is consumed successfully
- **THEN** subsequent presentations of the same token MUST be refused
- **AND** the package's partition_id MUST match the partition_id embedded in the signed token payload

### Requirement: Outbound Network Policy for User-Driven Egress
Any user-driven outbound network access from the bastion (URL fetches, integrations, webhooks, OIDC discovery follow-ups) SHALL be gated by an outbound network policy. The policy MUST block RFC1918, loopback, link-local, CGNAT, multicast, reserved, IPv6 link-local / ULA / multicast, and IPv4-mapped-IPv6 addresses. URL parsing MUST allowlist schemes and ports. Requests MUST be bound to the resolved IP at the time of policy evaluation to defeat DNS rebinding.

#### Scenario: SSRF to cloud metadata refused
- **WHEN** a user-driven fetch is attempted against `http://169.254.169.254/...` or `https://[::ffff:169.254.169.254]/...`
- **THEN** the outbound policy MUST refuse the request before any TCP connect

#### Scenario: DNS rebinding defeated
- **WHEN** a hostname resolves to a public address at policy-evaluation time but a private address at connect time
- **THEN** the actual HTTP connect MUST be to the resolved (policy-evaluated) address, not a re-resolution

#### Scenario: Scheme and port allowlisted
- **WHEN** an outbound URL specifies a non-http/https scheme or a non-allowlisted port
- **THEN** the policy MUST refuse before resolution

### Requirement: Server-Side WebRTC Signalling Filtering
The bastion's WebRTC signalling server SHALL apply codec, fingerprint-algorithm, and ICE-candidate allowlists on every SDP offer/answer and every ICE candidate. TURN credentials handed to the browser MUST be per-session ephemeral with sub-hour TTL. SDP renegotiation that introduces new media sections MUST be refused.

#### Scenario: Codec outside allowlist refused
- **WHEN** an SDP offer or answer contains a codec outside the documented allowlist (`avc1`, `vp8`, `vp09`, `av01`)
- **THEN** the signalling layer MUST reject the SDP before propagating it

#### Scenario: Private-network ICE candidate stripped
- **WHEN** an ICE candidate's address is in RFC1918 / loopback / link-local / CGNAT / multicast / IPv6 ULA
- **THEN** the candidate MUST be dropped before being forwarded

#### Scenario: TURN credentials are per-session
- **WHEN** the bastion delivers `iceServers` to a browser
- **THEN** the TURN username MUST encode a session-bound HMAC over an expiry timestamp; credentials MUST expire within one hour

### Requirement: eBPF Probe Safety
Agent-side eBPF probes feeding enhanced-recording telemetry SHALL use stable kernel ABIs (tracepoints, not kprobes/uprobes where avoidable), a documented minimum kernel version, an explicit capability precheck, and a safe-helper allowlist. Ring-buffer events ingested into the recording schema MUST be bounds-validated before storage. Enhanced recording MUST be off by default.

#### Scenario: Minimum kernel version enforced
- **WHEN** the agent starts on a kernel below the documented minimum
- **THEN** enhanced recording MUST refuse to load and surface a structured "kernel too old" reason

#### Scenario: Capability precheck
- **WHEN** the agent lacks the capabilities required to load probes
- **THEN** the agent MUST surface a structured "capability missing" reason before any load attempt

#### Scenario: Ring buffer events sanitised
- **WHEN** a probe writes an event into the ring buffer
- **THEN** the user-space consumer MUST validate `argc`, strip control bytes, and reject non-UTF-8 fields before persisting to the recording schema

### Requirement: Kubernetes Deploy Posture for the Bastion
The bastion's Kubernetes deployment SHALL run with: explicit NetworkPolicy default-deny for both ingress and egress with named allow edges; non-`privileged` containers (capability allowlist only); encrypted-at-rest persistent volumes; pod-level `runAsUser`, `fsGroup`, and `readOnlyRootFilesystem`; minimal bootstrap Job RBAC scoped by `resourceNames`. The agent DaemonSet MUST NOT use `privileged: true` when its required capabilities (`CAP_BPF`, `CAP_PERFMON`, `CAP_NET_RAW`) suffice.

#### Scenario: Cross-pod traffic restricted
- **WHEN** any namespace pod outside the named allow edges attempts to connect to a bastion control-plane pod
- **THEN** the connection MUST be refused by NetworkPolicy

#### Scenario: Agent DaemonSet not privileged
- **WHEN** the agent DaemonSet renders on a supported kernel
- **THEN** its pod spec MUST NOT set `privileged: true`; it MUST rely on its declared capability allowlist

#### Scenario: Recording PVC encrypted
- **WHEN** the recording storage PVC is provisioned
- **THEN** the storage class MUST enforce encryption at rest; installs without an encrypted storage class MUST require an explicit `--values insecure-storage.yaml` opt-in

### Requirement: Supply-Chain License and Vulnerability Gate
The bastion's CI SHALL enforce, on every PR: an AGPL transitive-import scan against documented Teleport package paths; a Rust advisory scan against any workspace member that pulls in the RDP connector tree; a Go advisory scan; pinned-by-SHA references for third-party CI actions used in release / publish workflows. Failures MUST block merge.

#### Scenario: AGPL guardrail fails build on offending import
- **WHEN** a PR introduces a dependency path that re-includes an AGPL-licensed Teleport module
- **THEN** `scripts/check-teleport-license-paths.sh` (or equivalent) MUST run in CI and fail the build with the offending path

#### Scenario: Floating action tags rejected in release workflow
- **WHEN** a release / publish workflow references `uses: <action>@<floating-tag>`
- **THEN** CI MUST refuse the change; only full commit SHAs are accepted

### Requirement: Recording Sensitive-Field Redaction Allowlist Discipline
Resources that store user-provided policy maps containing potentially sensitive fields (desktop target policies, file-transfer policies, recording policies) SHALL redact via a *denylist + structural rule* approach rather than a field allowlist. Adding a new field MUST default to redacted until explicitly proven non-sensitive.

#### Scenario: New policy field defaults to redacted
- **WHEN** a new attribute is added to a desktop / recording / file-transfer policy map
- **THEN** read actions MUST redact it by default; exempting the field MUST require an explicit non-sensitive declaration with a property-based regression test
