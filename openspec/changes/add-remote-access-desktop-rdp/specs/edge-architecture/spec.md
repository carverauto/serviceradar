## ADDED Requirements
### Requirement: Registered desktop access targets
ServiceRadar SHALL provide remote desktop/RDP access only to registered desktop targets selected by trusted inventory or policy, not by browser-supplied upstream hosts, ports, credentials, routes, or redirection settings.

#### Scenario: User opens a registered RDP target
- **GIVEN** an authenticated user is authorized to open a registered RDP desktop target
- **AND** the target has a selected agent route and trusted desktop policy
- **WHEN** the user starts a desktop access session
- **THEN** ServiceRadar SHALL derive the upstream host, port, TLS/NLA policy, credential mode, screen policy, redirection policy, approval requirement, quotas, and recording policy from trusted target state
- **AND** SHALL route the session through the selected agent.

#### Scenario: Client cannot select arbitrary desktop upstream or redirection
- **GIVEN** a browser or API client requests desktop access
- **WHEN** the request includes an upstream host, port, credential, route, gateway, agent, TLS override, redirection feature, quota, approval override, or recording override
- **THEN** ServiceRadar SHALL reject the request before dispatching any agent frame.

### Requirement: Desktop credentials are not shared master credentials
ServiceRadar SHALL avoid shared master desktop credentials and SHALL keep any desktop credential material memory-only and session-scoped.

#### Scenario: Session uses actor-backed desktop identity
- **GIVEN** a desktop target supports domain-backed delegation, smart-card authentication, certificate authentication, or another approved actor-backed credential mode
- **WHEN** ServiceRadar creates a desktop access session
- **THEN** ServiceRadar SHALL bind the credential mode to the actor, target, route, and session
- **AND** SHALL avoid persisting credential material in session metadata.

#### Scenario: Per-session user credential is memory-only
- **GIVEN** a desktop target policy allows users to enter their own target credentials
- **WHEN** the user authenticates to the RDP target
- **THEN** ServiceRadar SHALL keep the credential material memory-only
- **AND** SHALL erase it on session close, timeout, route loss, revocation, or authentication failure
- **AND** SHALL NOT expose it in recordings or audit metadata.

### Requirement: Desktop redirection features are disabled by default
ServiceRadar SHALL disable clipboard, drive, printer, audio, smart-card, file, and local-resource redirection by default and SHALL enable each feature only through explicit RBAC and target policy.

#### Scenario: Clipboard copy is denied by default
- **GIVEN** a desktop session is active
- **WHEN** the user attempts to copy data between the browser and remote desktop
- **THEN** ServiceRadar SHALL deny clipboard transfer unless target policy and user permission allow that direction and content type
- **AND** SHALL record the policy decision without storing clipboard content by default.

#### Scenario: Drive and printer redirection are denied by default
- **GIVEN** a desktop session is active
- **WHEN** the client or target attempts drive, file, or printer redirection
- **THEN** ServiceRadar SHALL deny the redirection unless explicit target policy and user permission allow it
- **AND** SHALL record the policy decision.

### Requirement: Desktop rendering uses typed graphical frames
ServiceRadar SHALL use a desktop-specific graphical frame protocol and SHALL NOT treat RDP sessions as terminal byte streams.

#### Scenario: Browser renderer exchanges graphical frames
- **GIVEN** a desktop session is active
- **WHEN** the target sends screen updates and the browser sends keyboard, pointer, resize, focus, or close events
- **THEN** ServiceRadar SHALL exchange typed desktop frames through the selected route
- **AND** SHALL enforce frame rate, bitrate, resolution, backpressure, idle timeout, and session TTL policy.

### Requirement: Desktop sessions are route-bound and revocable
ServiceRadar SHALL bind every desktop session to one selected route and SHALL terminate streams when the route, policy, approval, credential grant, or session is revoked.

#### Scenario: Route loss terminates desktop session
- **GIVEN** a desktop session is active through a selected agent route
- **WHEN** the selected route is lost or the session is revoked
- **THEN** ServiceRadar SHALL close the upstream desktop connection
- **AND** SHALL erase session credential material
- **AND** SHALL record the termination reason.

### Requirement: Desktop recording stores metadata by default
ServiceRadar SHALL record desktop session lifecycle, credential mode, redirection state, frame statistics, policy decisions, byte counts, timing, and failures without storing screen frames or redirected content by default.

#### Scenario: Desktop activity is recorded without screen content
- **GIVEN** a user opens a desktop session through ServiceRadar
- **WHEN** ServiceRadar writes audit or replay events
- **THEN** the event SHALL include actor, target, session, route, protocol, credential mode, screen policy, redirection feature state, policy decisions, frame statistics, byte counts, status, and timing metadata
- **AND** SHALL NOT include screen frames, screenshots, clipboard content, transferred file content, audio payloads, smart-card payloads, passwords, or generated private keys unless a future explicit content-retention policy enables that capture.

### Requirement: Device RDP launch resolves an exact authorized target
ServiceRadar SHALL expose a device remote-desktop action only when the current
actor can use an enabled registered target whose `device_uid` exactly matches
the inventory device.

#### Scenario: Authorized user launches RDP from device details
- **GIVEN** an authenticated user has `devices.remote_access.rdp.open`
- **AND** one enabled registered desktop target exactly matches the device UID
- **WHEN** the user selects RDP from device details and submits their own target credentials
- **THEN** ServiceRadar SHALL create the session from the registered target ID
- **AND** SHALL derive the upstream, route, TLS, CA, redirection, quota, approval, and recording policy from server-owned target state
- **AND** SHALL erase the submitted password from browser state after the session attach is accepted.

#### Scenario: Target belongs to another device
- **GIVEN** an authenticated user can open RDP on one device
- **WHEN** the client submits a desktop-target ID registered to another device
- **THEN** ServiceRadar SHALL reject the request before creating or dispatching a remote-access session.

### Requirement: TURN credentials are short-lived and file-backed
ServiceRadar SHALL keep TURN REST shared-secret material in an operator-owned
mounted Secret and SHALL mint a distinct time-bound credential for each remote
desktop viewer.

#### Scenario: Viewer receives an ephemeral TURN credential
- **GIVEN** an operator configured a TURN endpoint and a valid mounted TURN REST shared-secret file
- **WHEN** an authorized user creates a WebRTC viewer for an RDP session
- **THEN** ServiceRadar SHALL mint a session- or actor-bound HMAC TURN credential with a positive TTL no greater than one hour
- **AND** SHALL return only the public endpoint, expiring username, and derived credential to the browser
- **AND** SHALL NOT return, log, or persist the shared secret.

#### Scenario: TURN endpoint has no secure key custody
- **GIVEN** a TURN or TURNS endpoint is configured
- **WHEN** the mounted shared-secret file is absent, unreadable, weak, or supplied inline with ICE metadata
- **THEN** ServiceRadar SHALL fail configuration closed before accepting a desktop viewer.
