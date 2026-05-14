## ADDED Requirements
### Requirement: Registered Kubernetes access targets
ServiceRadar SHALL provide remote Kubernetes access only to registered cluster targets selected by trusted inventory or policy, not by browser-supplied API server URLs, kubeconfigs, tokens, or certificates.

#### Scenario: User opens a registered Kubernetes target
- **GIVEN** an authenticated user is authorized to open a registered Kubernetes cluster target
- **AND** the target has a selected agent route and trusted cluster policy
- **WHEN** the user starts a Kubernetes access session
- **THEN** ServiceRadar SHALL derive the API server URL, cluster CA, TLS server name, connector credential mode, actor identity mode, namespace/resource/verb policy, quotas, approval requirement, and recording policy from trusted target state
- **AND** SHALL route the session through the selected agent.

#### Scenario: Client cannot supply a kubeconfig or arbitrary API server
- **GIVEN** a browser or API client requests Kubernetes access
- **WHEN** the request includes an API server URL, kubeconfig, bearer token, client certificate, impersonation header, route, gateway, agent, TLS override, quota, approval override, or recording override
- **THEN** ServiceRadar SHALL reject the request before dispatching any agent frame.

### Requirement: Kubernetes identity is actor-preserving
ServiceRadar SHALL preserve the ServiceRadar actor identity when accessing registered Kubernetes clusters by using Kubernetes impersonation, short-lived client certificates, or another approved short-lived identity mode.

#### Scenario: Session uses Kubernetes impersonation
- **GIVEN** a Kubernetes target is configured for impersonation
- **AND** the ServiceRadar actor maps to approved Kubernetes user and group traits
- **WHEN** ServiceRadar dispatches an API, logs, exec, or port-forward request
- **THEN** the selected agent SHALL authenticate with the registered connector credential
- **AND** SHALL send only the policy-approved impersonated user, groups, and extra fields for that actor
- **AND** the target cluster SHALL authorize the request as the impersonated actor.

#### Scenario: Connector credentials are not exposed to the browser
- **GIVEN** a Kubernetes target requires a connector credential
- **WHEN** ServiceRadar creates a Kubernetes access session
- **THEN** ServiceRadar SHALL keep connector tokens, kubeconfigs, client private keys, and generated identity material out of browser storage and persisted session metadata
- **AND** the selected agent SHALL keep any granted credential material memory-only.

### Requirement: Kubernetes access policy constrains resources and streams
ServiceRadar SHALL enforce Kubernetes namespace, resource, verb, subresource, selector, exec, log, port-forward, timeout, and byte-quota policy before and during access.

#### Scenario: Approved API request is allowed
- **GIVEN** a Kubernetes target policy allows a user to `get` and `list` pods in namespace `ops`
- **WHEN** the user lists pods in namespace `ops`
- **THEN** ServiceRadar SHALL dispatch the request through the selected route
- **AND** SHALL record the policy decision and response metadata.

#### Scenario: Disallowed namespace or verb is denied
- **GIVEN** a Kubernetes target policy allows read-only access to namespace `ops`
- **WHEN** the user attempts to delete a pod, access another namespace, or use a disallowed subresource
- **THEN** ServiceRadar SHALL deny the request before dispatch
- **AND** SHALL record the denied policy decision.

#### Scenario: Exec command is constrained
- **GIVEN** a Kubernetes target policy allows pod exec only for approved namespaces, containers, commands, TTY mode, and duration
- **WHEN** the user starts an exec session
- **THEN** ServiceRadar SHALL enforce command, container, TTY, timeout, byte-quota, approval, and recording policy
- **AND** SHALL terminate the exec stream when the policy or route is revoked.

#### Scenario: Port-forward is constrained
- **GIVEN** a Kubernetes target policy allows port-forward only to approved resources and ports
- **WHEN** the user starts a port-forward stream
- **THEN** ServiceRadar SHALL enforce target, port, stream count, byte-quota, idle-timeout, approval, and recording policy
- **AND** SHALL reject attempts to change the destination after session creation.

### Requirement: Kubernetes sessions are route-bound and revocable
ServiceRadar SHALL bind every Kubernetes access session to one selected route and SHALL terminate streams when the route, policy, approval, identity, or session is revoked.

#### Scenario: Route loss terminates Kubernetes streams
- **GIVEN** a Kubernetes access session is streaming logs, exec, or port-forward data through a selected agent route
- **WHEN** the selected route is lost or the session is revoked
- **THEN** ServiceRadar SHALL cancel in-flight requests where possible
- **AND** SHALL close upstream Kubernetes streams
- **AND** SHALL record the termination reason.

### Requirement: Kubernetes recording stores metadata by default
ServiceRadar SHALL record Kubernetes session lifecycle, identity mode, request metadata, policy decisions, byte counts, timing, and failures without storing response bodies or stream payloads by default.

#### Scenario: Kubernetes API request is recorded without response body
- **GIVEN** a user sends a Kubernetes API request through ServiceRadar
- **WHEN** ServiceRadar writes audit or replay events
- **THEN** the event SHALL include actor, target, session, route, identity mode, impersonated user/groups when used, namespace, resource, subresource, verb, object name, policy decision, status, byte count, and timing metadata
- **AND** SHALL NOT include response bodies, log lines, exec stream payloads, port-forward payloads, connector tokens, kubeconfigs, or generated client private keys unless a future explicit content-retention policy enables payload capture.
