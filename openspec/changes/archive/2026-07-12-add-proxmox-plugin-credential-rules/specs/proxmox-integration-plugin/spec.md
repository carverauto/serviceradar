## ADDED Requirements

### Requirement: First-party Proxmox plugin package
The system SHALL provide a first-party Proxmox integration plugin built with a ServiceRadar WASM plugin SDK.

#### Scenario: Plugin package is importable
- **GIVEN** the Proxmox plugin bundle is built and signed by the release workflow
- **WHEN** an operator imports first-party plugin packages
- **THEN** the Proxmox plugin SHALL appear in the plugin catalog with manifest metadata, config schema, resource requests, and approved HTTP capability requirements

### Requirement: Proxmox API interrogation through host HTTP
The Proxmox plugin SHALL query Proxmox VE APIs through the ServiceRadar host-proxied HTTP capability and SHALL NOT open raw network sockets.

#### Scenario: Query Proxmox API with token auth
- **GIVEN** a plugin assignment contains a Proxmox target URL and a scoped credential broker grant
- **WHEN** the plugin runs
- **THEN** it SHALL call Proxmox API endpoints using host HTTP
- **AND** the edge credential broker SHALL inject token authentication into approved requests
- **AND** it SHALL emit status, latency, and endpoint result metadata without exposing the token

#### Scenario: Probe candidate without token auth
- **GIVEN** a plugin assignment or discovery task contains a candidate Proxmox target without a credential broker grant
- **WHEN** candidate probing is enabled
- **THEN** the plugin SHALL limit itself to unauthenticated fingerprint checks
- **AND** it SHALL report candidate evidence separately from authenticated enrichment
- **AND** it SHALL NOT downgrade to direct token fields or static fallback targets

#### Scenario: Host allowlist blocks unapproved endpoint
- **GIVEN** a plugin assignment target resolves outside the approved host/port allowlist
- **WHEN** the plugin attempts an HTTP request
- **THEN** the host runtime SHALL deny the request
- **AND** the plugin SHALL report an `UNKNOWN` or `CRITICAL` status without retrying with leaked credentials

### Requirement: Proxmox node and guest discovery
The Proxmox plugin SHALL discover PVE nodes, QEMU guests, and LXC guests and emit typed device discovery payloads.

#### Scenario: Discover node and guests
- **GIVEN** a reachable Proxmox VE API with at least one node and one guest
- **WHEN** the plugin queries cluster resources and node status
- **THEN** the plugin SHALL emit a `serviceradar.device_discovery.v1` payload containing the PVE node and guest devices
- **AND** the payload SHALL include stable identity hints for cluster, node, VMID, guest type, hostname/name, IP/MAC when available, and provider source

### Requirement: Proxmox resource efficiency metrics
The Proxmox plugin SHALL report resource-efficiency metrics for PVE nodes and guests when API data is available.

#### Scenario: Guest efficiency metrics emitted
- **GIVEN** a QEMU or LXC guest has current CPU, memory, disk, and allocation data in the Proxmox API
- **WHEN** the plugin runs
- **THEN** it SHALL emit metrics for usage, allocation, utilization ratio, and efficiency score
- **AND** it SHALL emit bottleneck events for configured thresholds such as high I/O wait, high memory pressure, or sustained CPU saturation

#### Scenario: Partial metrics are tolerated
- **GIVEN** a Proxmox endpoint omits disk or I/O fields for a guest
- **WHEN** the plugin builds the result
- **THEN** available CPU/memory metrics SHALL still be emitted
- **AND** missing metrics SHALL be marked unavailable rather than causing the whole plugin run to fail

### Requirement: Proxmox secret redaction
The Proxmox plugin SHALL never include raw Proxmox API tokens, passwords, tickets, CSRF tokens, or cookies in result details, metrics, events, or logs.

#### Scenario: API error body is sanitized
- **GIVEN** a Proxmox API request fails with an error response
- **WHEN** the plugin emits result details
- **THEN** any credential-bearing values SHALL be redacted
- **AND** error bodies SHALL be length-bounded

### Requirement: First-party Proxmox console plugin package
The system SHALL provide a first-party Proxmox console plugin package that uses the ServiceRadar console stream bridge and is assigned only through scoped `console_access` credential rules.

#### Scenario: Console plugin assignment is credential-rule scoped
- **GIVEN** an enabled Proxmox network credential rule with purpose `console_access`
- **WHEN** credential rule reconciliation runs for an in-scope agent
- **THEN** the system SHALL materialize a policy-derived assignment for the Proxmox console plugin package
- **AND** the assignment SHALL include a credential broker grant and credential rule identifier
- **AND** it SHALL NOT include decrypted SSH keys, passwords, API tokens, Proxmox tickets, CSRF tokens, or cookies

#### Scenario: Console package is importable
- **GIVEN** the first-party Wasm plugin bundles are built
- **WHEN** an operator imports first-party plugin packages
- **THEN** the Proxmox console plugin SHALL appear in the plugin catalog with manifest metadata, config schema, resource requests, and `proxmox_console_stream` capability requirements

#### Scenario: PVE SSH console is agent-hosted
- **GIVEN** an authorized Proxmox console session targets a PVE host and resolves to SSH mode
- **WHEN** the console plugin opens the ServiceRadar console bridge
- **THEN** the TinyGo/Wasm plugin SHALL delegate SSH transport to an agent-hosted connector
- **AND** the agent-hosted connector SHALL stream stdout, stderr, stdin, resize, and close frames over the existing console bridge
- **AND** the browser-to-core-to-gateway path SHALL remain ERTS/PubSub based after the agent gateway receives control-stream frames

#### Scenario: Brokered console credential resolution
- **GIVEN** a Proxmox console assignment carries a scoped credential broker grant
- **AND** the broker grant resolves to one-session SSH credential material or a native provider console ticket
- **WHEN** an authorized PVE SSH console session starts
- **THEN** the agent-hosted connector SHALL use only that session-scoped broker result
- **AND** reusable agent-local SSH private keys, passwords, and passphrases SHALL NOT be supported
- **AND** the browser, gateway metadata, and audit payload SHALL NOT receive the SSH private key, passphrase, password, Proxmox ticket, CSRF token, or cookie
