## ADDED Requirements

### Requirement: Native Proxmox guest terminal admission
The system SHALL provide a native terminal-console path for an LXC guest or a
QEMU guest with a supported serial terminal only when trusted virtualization
inventory uniquely resolves the canonical guest, cluster, node, VMID, and guest
kind and a selected edge agent has a partition-bound, credential-scoped console
assignment. The system SHALL reject identity ambiguity, stale or missing guest
links, client-supplied provider routing, and unsupported console types before
credential resolution.

#### Scenario: Uniquely resolved LXC terminal opens
- **GIVEN** a canonical LXC device has one fresh cluster/node/VMID identity
- **AND** an authorized user selects the guest-terminal action
- **AND** a partition-bound console assignment selects one reachable agent
- **WHEN** the user creates a terminal session
- **THEN** the system SHALL create a session bound to that exact guest identity
  and selected route
- **AND** the browser SHALL not provide the PVE endpoint, node, VMID, agent, or
  credential rule

#### Scenario: Ambiguous guest is unavailable
- **GIVEN** a guest name, VMID, alias, or device link resolves to multiple or no
  trusted virtualization identities
- **WHEN** a console session is requested
- **THEN** the system SHALL reject the request before resolving a provider
  credential or ticket
- **AND** it SHALL report only a non-secret unavailable reason to an authorized
  operator

### Requirement: Provider-native terminal ticket custody
The selected edge agent SHALL request and terminate the Proxmox terminal
console ticketed websocket for the admitted LXC or serial-QEMU guest. Provider
credentials, authentication cookies, CSRF material, tickets, websocket URLs,
and guest credentials SHALL remain out of browser-visible data, persisted
session metadata, audit payloads, logs, and URLs.

#### Scenario: Browser receives only ServiceRadar terminal frames
- **GIVEN** an admitted guest-terminal session has a valid browser attach ticket
- **WHEN** the browser attaches to the ServiceRadar terminal endpoint
- **THEN** the selected agent SHALL use the session-scoped provider grant to
  obtain and terminate the provider console connection
- **AND** the browser SHALL receive only bounded ServiceRadar terminal/control
  frames
- **AND** the browser SHALL not receive a Proxmox credential or console ticket

#### Scenario: Provider ticket is cleared on termination
- **GIVEN** the adapter has obtained a provider terminal ticket
- **WHEN** the session closes, expires, loses its route, or encounters an error
- **THEN** the adapter SHALL close the provider connection and clear ticket and
  credential-grant buffers
- **AND** the system SHALL emit a redacted session outcome

### Requirement: Terminal-only Proxmox guest console scope
The first native guest-console implementation SHALL support LXC terminal
consoles and QEMU serial terminals only. It SHALL keep graphical
VNC/noVNC/SPICE/RFB console paths and Windows desktop access unavailable.

#### Scenario: Graphical-only QEMU guest remains disabled
- **GIVEN** a QEMU guest has no supported serial terminal or requests a
  graphical console path
- **WHEN** an operator views the device details or requests console access
- **THEN** the system SHALL not open a graphical provider console
- **AND** it SHALL return a non-secret terminal-unavailable outcome

#### Scenario: Provider TLS validation fails closed
- **GIVEN** the selected PVE presents a certificate that fails the registered
  server-identity or CA trust policy
- **WHEN** the agent attempts to establish the provider terminal connection
- **THEN** the adapter SHALL refuse the connection
- **AND** it SHALL not fall back to insecure TLS verification

### Requirement: Guest-console authorization and audit
Guest-console access SHALL require explicit console authorization in addition
to device visibility and SHALL retain the existing single-use browser ticket,
session timeout, route binding, and lifecycle audit controls. Audit records
shall identify the ServiceRadar actor and provider-console custody mode without
claiming that the provider ticket authenticates that actor inside the guest OS.

#### Scenario: Viewer cannot obtain guest-console details
- **GIVEN** a user can view a guest device but lacks console authorization
- **WHEN** the user requests a guest terminal action or session
- **THEN** the system SHALL deny the request without resolving provider
  credentials, tickets, or target routing details

#### Scenario: Guest-console lifecycle is redacted and bound
- **GIVEN** an authorized user opens a guest terminal through a selected agent
- **WHEN** the session starts and later stops
- **THEN** audit events SHALL include actor, session, canonical guest, cluster,
  node, VMID, guest kind, selected agent/partition, policy result, timestamps,
  and normalized close reason
- **AND** audit events SHALL exclude terminal bytes, provider secrets, tickets,
  cookies, URLs, and guest credentials
