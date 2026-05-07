## ADDED Requirements

### Requirement: Proxmox web console sessions
The system SHALL allow authorized operators to open browser-based console sessions to Proxmox PVE hosts through a scoped edge agent, and SHALL report QEMU/LXC guest console paths as unavailable until a native Proxmox guest console connector is enabled.

#### Scenario: Open PVE host shell
- **GIVEN** a Proxmox PVE host has a matching SSH credential rule and reachable assigned agent
- **AND** the user has Proxmox console permission
- **WHEN** the user opens the PVE shell from device details
- **THEN** web-ng SHALL create a short-lived single-use console session ticket
- **AND** the browser SHALL connect to a web terminal websocket
- **AND** terminal I/O SHALL be proxied through the authorized edge agent to the PVE host SSH session

#### Scenario: Open guest console
- **GIVEN** a Proxmox guest device is enriched with cluster, node, VMID, and guest type
- **AND** a credential rule authorizes console access through the assigned edge agent
- **WHEN** the user opens the VM or LXC console
- **THEN** the system SHALL open a guest console using a supported Proxmox console path or report that the console path is unavailable for that guest
- **AND** it SHALL NOT require the user's browser to reach the PVE API endpoint directly

### Requirement: Console access authorization and audit
Console access SHALL require explicit authorization and SHALL emit audit events for session lifecycle.

#### Scenario: Viewer cannot open console
- **GIVEN** a user can view a Proxmox device but lacks console permission
- **WHEN** the user attempts to open a console session
- **THEN** the request SHALL be denied
- **AND** no credential material SHALL be resolved

#### Scenario: Session lifecycle audited
- **GIVEN** an authorized user opens a Proxmox console
- **WHEN** the session starts and later ends
- **THEN** the system SHALL emit audit events containing user ID, device ID, session ID, target kind, assigned agent, start time, end time, and close reason
- **AND** audit events SHALL NOT include terminal data, SSH private key material, Proxmox tickets, or passwords

### Requirement: Short-lived console tickets
The system SHALL use short-lived single-use tickets for browser websocket console attachment.

#### Scenario: Ticket cannot be reused
- **GIVEN** a console session ticket has already been used
- **WHEN** a second websocket attempts to attach with the same ticket
- **THEN** the request SHALL be rejected
- **AND** the active session SHALL remain unaffected

#### Scenario: Expired ticket is rejected
- **GIVEN** a console session ticket has expired
- **WHEN** a websocket attempts to attach with the expired ticket
- **THEN** the request SHALL be rejected before any edge credential is resolved

### Requirement: Console credential redaction
Console session handling SHALL keep SSH keys, passphrases, Proxmox tickets, cookies, and CSRF tokens out of URLs, logs, audit payloads, and terminal metadata.

#### Scenario: Credential-bearing fields are redacted
- **GIVEN** a console session fails during SSH or Proxmox console negotiation
- **WHEN** the failure is logged or shown in UI
- **THEN** sensitive credential values SHALL be redacted
- **AND** the operator-facing error SHALL identify the failing phase without exposing secrets

### Requirement: Web terminal component integration
The web UI SHALL provide a browser terminal component for Proxmox console sessions using the existing web-ng React integration.

#### Scenario: Terminal renders in device details workflow
- **GIVEN** an authorized console session has been created
- **WHEN** the user opens the terminal view
- **THEN** a React/xterm.js component SHALL render inside the Phoenix web-ng shell
- **AND** it SHALL handle terminal output, user input, resize events, focus, connection close, and reconnect-denied states

### Requirement: Console session limits
Console sessions SHALL enforce resource, idle, and absolute duration limits.

#### Scenario: Idle session closes
- **GIVEN** a console session is open
- **WHEN** no terminal input or output occurs for the configured idle timeout
- **THEN** the system SHALL close the session
- **AND** emit an audit event with close reason `idle_timeout`

#### Scenario: Agent disconnect closes session
- **GIVEN** a console session is proxied through an edge agent
- **WHEN** the edge agent disconnects
- **THEN** web-ng SHALL close the browser websocket
- **AND** the terminal UI SHALL show a disconnected state without exposing internal credential details
