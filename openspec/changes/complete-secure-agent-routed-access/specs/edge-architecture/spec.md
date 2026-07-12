## ADDED Requirements

### Requirement: Remote-access credentials are released only to a bound session
The platform SHALL release SSH, RDP, and provider-console credential material only after authorization into a short-lived grant bound to one actor, session, registered target, protocol, agent, gateway, and expiry. Durable agent/add-on configuration MUST NOT contain reusable plaintext remote-access credentials.

#### Scenario: Add-on assignment is generated
- **WHEN** core compiles durable configuration for a remote-access-capable agent or provider adapter
- **THEN** the assignment contains non-secret target and policy references but no decrypted SSH, RDP, PVE, VNC, cookie, ticket, or CSRF material

#### Scenario: Bound session opens
- **WHEN** an authorized session is attached on its selected route
- **THEN** only that route receives the bounded credential grant and the grant expires or is revoked with the session

### Requirement: Graphical remote access uses bounded media transport
RDP and QEMU graphical consoles SHALL use the desktop-media and desktop-control paths for screen, cursor, input, quality, close, and backpressure rather than terminal byte streams.

#### Scenario: Graphical frame burst
- **WHEN** an RDP or QEMU adapter produces screen updates faster than the browser consumes them
- **THEN** byte credit, queue bounds, frame/bitrate policy, and stale-frame handling bound memory and bandwidth without routing frames through xterm

#### Scenario: Route loss during graphical access
- **WHEN** the selected edge route disconnects
- **THEN** media and control close, adapter resources and credentials are released, and the session records a route-loss terminal outcome

### Requirement: Remote-access public errors are typed and redacted
The platform SHALL map internal adapter, network, authentication, host-key, TLS, credential, and provider errors to bounded public error codes before sending them to browsers, recordings, or user-visible audit fields.

#### Scenario: Provider returns a sensitive error
- **WHEN** PVE, SSH, RDP, a credential broker, or a helper returns an error containing an endpoint, username, token fragment, or upstream message
- **THEN** the browser receives only the typed public code and internal diagnostics are structured and redacted
