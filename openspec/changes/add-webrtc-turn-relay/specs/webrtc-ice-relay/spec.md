## ADDED Requirements

### Requirement: Shared ICE credential provider
The system SHALL provide one ICE credential provider that mints per-viewer ICE servers for every WebRTC feature: camera relay viewers and remote desktop sessions.
The provider SHALL support the backends `none`, `static_secret` and `cloudflare`.
A deployment SHALL select exactly one backend.
Every minted credential SHALL be bound to one viewer subject and carry an expiry no more than 3600 seconds after issue.

#### Scenario: Camera relay viewer receives a minted credential
- **GIVEN** a deployment with the `static_secret` backend and a valid mounted shared secret
- **WHEN** an authorized browser starts WebRTC negotiation for a camera relay session
- **THEN** the signaling response SHALL include TURN servers with a username that encodes an expiry within the configured TTL
- **AND** the credential SHALL be the TURN REST HMAC of that username under the shared secret

#### Scenario: Remote desktop keeps its existing behavior
- **GIVEN** a deployment configured through the existing remote desktop TURN values
- **WHEN** a remote desktop WebRTC viewer is created
- **THEN** the provider SHALL mint the same credential the pre-existing remote desktop minting would have produced for the same inputs

### Requirement: Static ICE configuration carries no credentials
The system SHALL accept only `stun:`, `stuns:`, `turn:` and `turns:` URLs in static ICE configuration.
It SHALL reject usernames, credentials, shared secrets and userinfo supplied in Helm values, ICE JSON, environment values or browser input.

#### Scenario: Credential in values is rejected
- **WHEN** an operator sets an ICE server entry that includes a `credential` key in Helm values
- **THEN** chart rendering SHALL fail with an error naming the rejected key

### Requirement: TURN shared secret is a deployment infrastructure secret
The system SHALL read the TURN REST shared secret only from an operator-owned Kubernetes Secret file mounted into the web-ng, core-elx and TURN server workloads.
It SHALL NOT store the shared secret in `platform.network_credential_secrets`, and SHALL NOT return, log or persist it.

#### Scenario: Secret never reaches the browser
- **GIVEN** the `static_secret` backend is enabled
- **WHEN** any viewer receives ICE servers
- **THEN** the response SHALL contain only public URLs, an expiring username and a derived credential
- **AND** neither the shared secret nor any Cloudflare token or key secret SHALL appear in responses, logs or persisted records other than the encrypted credential store

### Requirement: Cloudflare credentials use the unified credential model
The system SHALL store the operator's Cloudflare API token and every provisioned Cloudflare TURN key secret encrypted in `platform.network_credential_secrets` under the native descriptor `cloudflare`.
The deployment WebRTC relay settings SHALL reference them directly with restrictive foreign keys, appear as their consumer in the credential-usage inventory, and block their deletion while referenced.
No Helm value or mounted file SHALL supply the Cloudflare token.

#### Scenario: Credential deletion is guarded while referenced
- **GIVEN** the relay settings reference a `cloudflare` API-token credential
- **WHEN** an operator tries to delete that credential
- **THEN** the deletion SHALL be refused
- **AND** the credential's usage view SHALL list "Media relay (TURN)" as a consumer with a link to its settings

### Requirement: Cloudflare TURN key provisioning
The system SHALL let an operator with `settings.webrtc.manage` select a `cloudflare` credential in Settings -> Media relay (TURN) and provision, rotate and revoke the TURN key through Cloudflare's API via `ServiceRadar.HTTP.EgressClient`.
Provisioning SHALL be idempotent per attempt and SHALL NOT leave an untracked TURN key in the operator's account.

#### Scenario: Provisioning succeeds
- **GIVEN** a valid Cloudflare API token credential with Realtime edit permission
- **WHEN** the operator clicks Provision
- **THEN** a TURN key SHALL be created in the operator's account
- **AND** its secret SHALL be stored as a `cloudflare` credential referenced by the relay settings
- **AND** the settings status SHALL become `provisioned` and the `cloudflare` backend SHALL become selectable

#### Scenario: Provisioning failure leaves no orphan key
- **GIVEN** Cloudflare creates the TURN key but storing its secret fails
- **WHEN** the provisioning job handles the failure
- **THEN** it SHALL delete the created key on Cloudflare before reporting `failed`
- **AND** if that delete fails, the attempt SHALL be recorded as `orphaned_key` with the key ID and a cleanup job SHALL retry the delete

#### Scenario: Retried attempt reuses its key
- **GIVEN** a provisioning attempt created a key and the job was retried before recording it
- **WHEN** the retry runs
- **THEN** it SHALL find the key it created by its attempt-derived name instead of creating a second key

### Requirement: Cloudflare TURN backend
When the `cloudflare` backend is selected, the system SHALL mint per-viewer credentials by calling Cloudflare's TURN key credential API through `ServiceRadar.HTTP.EgressClient`, with a bounded TTL and a request timeout.
It SHALL pass through only returned ICE server URLs that use an allowed scheme.

#### Scenario: Cloudflare mint succeeds
- **GIVEN** the `cloudflare` backend with a provisioned TURN key
- **WHEN** a viewer starts negotiation
- **THEN** the provider SHALL request credentials with the configured TTL through the egress client
- **AND** SHALL return the validated ICE servers to that viewer only

### Requirement: Mint failure degrades without breaking playback
When the provider cannot mint credentials, the system SHALL return the STUN-only ICE list with an `ice_credentials` status of `unavailable`.
It SHALL emit telemetry and an operator-visible health signal naming the backend and failure class.
The viewer SHALL remain eligible for the websocket fallback transports.

#### Scenario: Cloudflare is unreachable
- **GIVEN** the `cloudflare` backend and an egress path that times out
- **WHEN** a viewer starts negotiation
- **THEN** the viewer SHALL receive the STUN-only list and status `unavailable`
- **AND** a mint-failure telemetry event SHALL be emitted with reason class `timeout`

### Requirement: Credential minting is rate limited
The system SHALL limit credential minting per actor and per viewer session.
It SHALL answer requests over the limit with the STUN-only list and a rate-limited status instead of minting.

#### Scenario: Viewer exceeds the per-session limit
- **GIVEN** a per-session limit of 6 mints per minute
- **WHEN** a single viewer session requests a seventh mint within one minute
- **THEN** no credential SHALL be minted for that request
- **AND** the response SHALL carry the rate-limited status

### Requirement: Optional chart-managed TURN server
The Helm chart SHALL offer an optional TURN server, disabled by default.
When enabled, it SHALL expose UDP and TCP 3478 and, optionally, TLS 5349 to clients, through the shared Gateway API gateway when available or otherwise a LoadBalancer or NodePort Service.
Its relay port range SHALL be bounded and reachable only from inside the cluster.
It SHALL require an explicit external hostname and authenticate with the same shared-secret Secret as the `static_secret` backend.
It SHALL deny relaying to loopback, link-local, RFC 1918, CGNAT, ULA and the configured cluster pod and service CIDRs, except its own relay addresses and the release's core-elx pod addresses.

#### Scenario: Enabled without an external hostname
- **WHEN** an operator enables the TURN server without setting its external hostname
- **THEN** chart rendering SHALL fail with an error naming the missing value

#### Scenario: Relay to an unrelated cluster address is refused
- **GIVEN** the chart-managed TURN server is running
- **WHEN** an authenticated client requests a relay permission for a pod CIDR address that is neither a core-elx pod nor the server's own relay address
- **THEN** the TURN server SHALL refuse the permission

#### Scenario: Relay to core-elx is permitted
- **GIVEN** the chart-managed TURN server is running
- **WHEN** an authenticated browser requests a relay permission for a core-elx WebRTC candidate address
- **THEN** the TURN server SHALL grant the permission

### Requirement: Forced relay requires a credential backend
The system SHALL support an operator option that makes browsers use relay-only ICE (`iceTransportPolicy: relay`).
It SHALL reject that option when the credential backend is `none`.

#### Scenario: Forced relay without a backend
- **WHEN** an operator enables forced relay with the backend set to `none`
- **THEN** chart rendering SHALL fail with an error explaining that forced relay needs a credential backend

### Requirement: ICE outcomes are observable
The system SHALL emit telemetry for every credential mint attempt (backend, result, duration) and for each WebRTC viewer's selected candidate-pair type (host, srflx, relay), through the JetStream telemetry pipeline.

#### Scenario: Viewer connects over a relay
- **WHEN** a viewer's selected ICE candidate pair uses a relay candidate
- **THEN** a candidate-pair telemetry event SHALL record type `relay` for that feature

### Requirement: Relay usage flows through JetStream
The system SHALL publish WebRTC mint, connection-outcome and Cloudflare TURN usage metrics to JetStream subjects under `metrics.timeseries.webrtc`, persisted by EventWriter, and SHALL NOT write them to a database directly.
The chart SHALL grant the core and web-ng NATS identities publish permission on exactly `metrics.timeseries.webrtc.>`.

#### Scenario: Usage samples arrive via JetStream
- **GIVEN** the `cloudflare` backend is provisioned
- **WHEN** the usage poller runs
- **THEN** it SHALL publish TURN usage samples to `metrics.timeseries.webrtc.cloudflare`
- **AND** the samples SHALL become queryable only after EventWriter persists them

### Requirement: Relay usage dashboard
The system SHALL show, on Settings -> Media relay (TURN), the relay share of successful viewer connections, mint failures by reason class and, for Cloudflare, relayed bytes per day over 30 days, and SHALL raise an alert when relayed bytes cross an operator-set monthly threshold.

#### Scenario: Dashboard shows relay share
- **GIVEN** viewer-connection metrics with 3 relay and 7 direct or srflx outcomes in the selected window
- **WHEN** an operator opens the usage panel
- **THEN** the panel SHALL show a relay share of 30%
