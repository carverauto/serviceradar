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
- **GIVEN** a plugin assignment contains a Proxmox target URL and scoped API token credentials
- **WHEN** the plugin runs
- **THEN** it SHALL call Proxmox API endpoints using host HTTP
- **AND** it SHALL include token authentication in headers
- **AND** it SHALL emit status, latency, and endpoint result metadata without exposing the token

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
