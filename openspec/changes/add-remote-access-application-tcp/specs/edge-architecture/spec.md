## ADDED Requirements
### Requirement: Registered application access targets
ServiceRadar SHALL provide remote application access only to registered HTTP/HTTPS application targets selected by trusted inventory or policy, not by browser-supplied upstream addresses.

#### Scenario: Browser opens a registered internal app
- **GIVEN** an authenticated user is authorized to open a registered application target
- **AND** the target has a selected agent route and trusted upstream policy
- **WHEN** the user starts an application access session
- **THEN** ServiceRadar SHALL derive the upstream scheme, host, port, Host header, SNI, TLS policy, allowed paths, allowed methods, quotas, approval requirement, and recording policy from trusted target state
- **AND** SHALL route the session through the selected agent.

#### Scenario: Browser cannot select an arbitrary upstream
- **GIVEN** a browser or API client requests application access
- **WHEN** the request includes an upstream host, port, route, gateway, agent, Host header, SNI, TLS verification override, credential rule, quota, approval override, or recording override
- **THEN** ServiceRadar SHALL reject the request before dispatching any agent frame.

### Requirement: Application access prevents SSRF and open-proxy behavior
ServiceRadar SHALL enforce SSRF and open-proxy protections for application access before any selected agent opens an upstream connection.

#### Scenario: Unsupported scheme or redirect is denied
- **GIVEN** a registered application target allows HTTP or HTTPS access only to a configured upstream
- **WHEN** a request or upstream redirect attempts to use an unsupported scheme, policy-external host, policy-external port, or unapproved Host/SNI value
- **THEN** ServiceRadar SHALL deny or stop the request
- **AND** SHALL emit an audit/recording event without exposing sensitive header or body values.

#### Scenario: CONNECT tunneling is not available through application access
- **GIVEN** a browser session is opened for a registered HTTP application
- **WHEN** the browser attempts arbitrary CONNECT tunneling or raw TCP forwarding through that session
- **THEN** ServiceRadar SHALL reject the behavior unless a separately registered TCP target and permissioned TCP adapter are used.

### Requirement: Application access isolates browser origin and headers
ServiceRadar SHALL isolate browser application sessions and enforce header/cookie policy so private upstream applications do not receive ServiceRadar credentials or unrelated app state.

#### Scenario: Sensitive headers are stripped
- **GIVEN** a browser sends a request through an application access session
- **WHEN** web-ng and the selected agent forward the request upstream
- **THEN** ServiceRadar SHALL strip ServiceRadar authentication headers, hop-by-hop proxy headers, and other policy-denied headers
- **AND** SHALL inject only policy-approved upstream headers.

#### Scenario: Application session origin is isolated
- **GIVEN** two registered application targets are opened by the same browser
- **WHEN** each target sets cookies or uses browser storage through the ServiceRadar access surface
- **THEN** the sessions SHALL use isolated origin or path namespaces so app state cannot collide across targets.

### Requirement: Registered TCP access targets
ServiceRadar SHALL provide raw TCP access only for explicitly registered TCP targets with route, protocol, quota, timeout, recording, and approval policy selected by trusted state.

#### Scenario: TCP target opens through selected route
- **GIVEN** an authenticated user is authorized to open a registered TCP target
- **WHEN** the user starts the TCP session
- **THEN** ServiceRadar SHALL route bounded data frames through the selected agent to the registered host and port
- **AND** SHALL enforce idle timeout, byte quotas, lifecycle audit, and recording policy.

#### Scenario: TCP target cannot become arbitrary forwarding
- **GIVEN** a TCP access session is active
- **WHEN** the client attempts to change the upstream host, port, protocol, route, credential, or policy after session creation
- **THEN** ServiceRadar SHALL reject the request or close the session.

### Requirement: Application and TCP recording stores metadata by default
ServiceRadar SHALL record application/TCP lifecycle, policy, request/response metadata, byte counts, and failures without storing request or response bodies by default.

#### Scenario: HTTP request is recorded without body content
- **GIVEN** a user sends an HTTP request through application access
- **WHEN** ServiceRadar writes replay or audit events
- **THEN** the event SHALL include actor, target, session, route, method, redacted path, status code, byte counts, policy decision, and timing metadata
- **AND** SHALL NOT include cookies, authorization headers, request bodies, or response bodies unless a future explicit content-retention policy enables it.
