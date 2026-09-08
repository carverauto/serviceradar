## ADDED Requirements

### Requirement: Privileged Proxmox effects use host-constructed semantic operations
The Wasm runtime SHALL expose bounded semantic Proxmox operations for authenticated inventory and console effects. The trusted agent host SHALL construct the final HTTP, WebSocket, or SSH request from the host-only grant and authoritative inventory state; it SHALL NOT accept a plugin-authored privileged request as authoritative.

#### Scenario: Plugin requests allowed inventory operation
- **GIVEN** an assignment permits the semantic operation `node_status` for one v3 Proxmox node
- **WHEN** Wasm requests `node_status` with that non-secret object selector
- **THEN** trusted host code SHALL derive the exact controller origin, method, path/query, body policy, TLS policy, and authentication fields
- **AND** Wasm SHALL receive only the bounded non-secret result fields declared for that operation

#### Scenario: Plugin requests arbitrary privileged operation
- **GIVEN** a plugin has a Proxmox host capability
- **WHEN** it supplies an arbitrary URL, method, path, query, body, protected header, SSH target, or provider ticket outside the semantic operation contract
- **THEN** the host SHALL deny the request before secret resolution or network dial
- **AND** it SHALL NOT translate the request through a generic credential-injecting connector

### Requirement: Proxmox connectors enforce the complete target and request policy
Before resolving a secret and before connecting, the trusted connector SHALL enforce the grant's exact scheme, canonical hostname/origin, effective port, normalized/resolved address policy, provider target, integration/controller/cluster/node/guest identity, TLS policy, semantic operation, method, normalized path/query, body policy, redirect policy, protected headers, and agent route.

#### Scenario: Exact HTTPS operation is authorized
- **GIVEN** a grant authorizes one HTTPS Proxmox operation to one canonical controller origin and approved resolved address set
- **WHEN** the connector builds the request
- **THEN** it SHALL use the granted effective port, verified TLS, approved SNI/trust roots, host-owned authentication, normalized operation path/query, and bounded body
- **AND** the dial SHALL use an address validated for that same origin and policy decision

#### Scenario: Network target representation changes
- **GIVEN** a plugin attempts a different scheme, explicit or implicit port, DNS name, IP literal, alternate textual IP encoding, resolved address, Host header, SNI name, integration/controller, cluster, node, VMID/type, agent route, or canonical origin
- **WHEN** the connector validates the operation
- **THEN** it SHALL deny the operation before credential resolution or dial
- **AND** it SHALL NOT fall back to the assignment URL, guest IP, another cluster node, or a less restrictive network path

#### Scenario: TLS policy is weakened
- **GIVEN** a plugin asks to skip certificate verification, change trust roots, change SNI, downgrade the scheme, or weaken the minimum TLS policy
- **WHEN** a credential-bearing Proxmox operation is evaluated
- **THEN** the connector SHALL reject the request
- **AND** production and demo credentials SHALL never be sent under the weakened policy

#### Scenario: Path query or body is substituted
- **GIVEN** a semantic operation has an allowlisted method, normalized path/query template, and body schema or digest
- **WHEN** Wasm attempts path traversal, alternate normalization, extra query fields, query smuggling, a different method, or an unapproved body field/value
- **THEN** the connector SHALL reject the operation before resolution or dial
- **AND** protected body values SHALL be constructed only by trusted host code

### Requirement: Plugins cannot supply or override protected authentication fields
The trusted connector SHALL own `Authorization`, `Proxy-Authorization`, `Cookie`, `Host`, CSRF, Proxmox ticket, WebSocket authentication/upgrade fields, SSH credential material, and any field classified as protected by the semantic operation. Plugin-provided protected fields SHALL cause denial rather than being forwarded or merged.

#### Scenario: Plugin supplies Authorization header
- **GIVEN** a Proxmox operation uses brokered token authentication
- **WHEN** Wasm supplies an `Authorization` header or equivalent target substitution
- **THEN** the host SHALL reject the request before resolver invocation
- **AND** it SHALL NOT overwrite the plugin value and continue

#### Scenario: Plugin supplies cookie or provider ticket
- **GIVEN** a native console operation requires host-owned ticket, cookie, or CSRF state
- **WHEN** Wasm supplies or modifies any such value
- **THEN** the operation SHALL be rejected
- **AND** the supplied value SHALL be redacted from diagnostics and audit

### Requirement: Redirects and DNS changes cannot escape authorization
Credential-bearing Proxmox connectors SHALL deny redirects by default and SHALL couple address validation to the actual dial. Any explicitly permitted redirect or DNS refresh SHALL undergo the complete authorization policy again before credentials are forwarded.

#### Scenario: Proxmox API redirects to another origin
- **GIVEN** an authorized Proxmox API request receives a redirect
- **WHEN** the redirect target differs in scheme, origin, effective port, address, path policy, or provider target
- **THEN** the connector SHALL stop without forwarding authentication
- **AND** it SHALL emit a redacted redirect-denied audit event

#### Scenario: DNS answer changes after validation
- **GIVEN** a hostname passed policy validation with an approved address
- **WHEN** resolution changes or the connection would dial another address
- **THEN** the connector SHALL reject or revalidate the complete policy against the actual dial address
- **AND** it SHALL NOT send credentials based on an earlier DNS result

### Requirement: Proxmox WebSocket and SSH sessions are exact-target connections
The native console connector SHALL enforce the exact authorized WebSocket or SSH endpoint and session fields. Wasm and browser input SHALL NOT substitute the target, route, authentication, or verification policy.

#### Scenario: Native guest WebSocket opens
- **GIVEN** a one-use grant identifies one session, v3 guest, owner node, controller origin, console mode, and provider ticket operation
- **WHEN** the connector opens the WebSocket
- **THEN** it SHALL use the exact host-constructed secure WebSocket origin, normalized path/query, owner node, VMID/type, and host-owned ticket/authentication
- **AND** any mismatch SHALL consume no broader credential and open no alternate connection

#### Scenario: PVE SSH opens
- **GIVEN** a one-session grant identifies one v3 PVE node, host, port, username/principal, allowed address, and host-key policy
- **WHEN** the connector opens SSH
- **THEN** it SHALL verify the host key under that exact policy and use only the session-scoped credential
- **AND** plugin-selected host, port, username, address, private key, password, or skip-verify behavior SHALL be rejected
