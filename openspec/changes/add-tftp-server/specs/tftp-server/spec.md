## ADDED Requirements

### Requirement: TFTP Session Lifecycle
The system SHALL provide on-demand TFTP server sessions in two modes: **receive** (device writes to agent) and **serve** (device reads from agent). Sessions MUST be created, monitored, and terminated through the command bus. The TFTP server on the agent MUST only run during an active session and MUST auto-stop after transfer completion, timeout, or cancellation.

#### Scenario: Operator creates a receive session
- **WHEN** an authenticated operator with `tftp.session.create` permission submits a receive-mode TFTP session specifying target agent, expected filename, and storage destination
- **THEN** a `TftpSession` resource is created and transitions to `queued`
- **AND** a `tftp.start_receive` command is dispatched to the target agent via the command bus

#### Scenario: Operator creates a serve session
- **WHEN** an authenticated operator with `tftp.session.create` permission submits a serve-mode TFTP session specifying target agent, a software image from the library, and a filename
- **THEN** a `TftpSession` resource is created and transitions to `queued`
- **AND** a `tftp.stage_image` command is dispatched to stage the image on the agent
- **AND** after staging completes, a `tftp.start_serve` command starts the TFTP server in read mode

#### Scenario: Receive-mode transfer completes
- **WHEN** the network device completes a TFTP PUT to the agent
- **THEN** the agent computes a SHA-256 checksum of the received file
- **AND** the agent streams the file to the gateway via `UploadFile` gRPC, which forwards to core
- **AND** the agent sends a `CommandResult` with success, file size, and checksum
- **AND** the TFTP server on the agent stops
- **AND** the session transitions through `completed` → `storing` → `stored`

#### Scenario: Serve-mode transfer completes
- **WHEN** the network device completes a TFTP GET from the agent
- **THEN** the agent sends a `CommandResult` with success and bytes served
- **AND** the TFTP server on the agent stops
- **AND** the staged image is cleaned up from the agent
- **AND** the session transitions to `completed`

#### Scenario: Session times out
- **WHEN** no TFTP connection is received within the configured timeout period
- **THEN** the TFTP server on the agent stops
- **AND** the session transitions to `expired`
- **AND** staging files are cleaned up

#### Scenario: Operator cancels a session
- **WHEN** an authenticated operator with `tftp.session.cancel` permission cancels an active session
- **THEN** a `tftp.stop_session` command is dispatched to the agent
- **AND** the TFTP server stops immediately
- **AND** the session transitions to `canceled`
- **AND** any partial or staged files are discarded

### Requirement: TFTP Receive Mode State Machine
Receive-mode sessions MUST follow the state machine: configuring → queued → waiting → receiving → completed → storing → stored, with failure transitions to `failed` and timeout/cancel transitions from any active state.

#### Scenario: Receive-mode state progression
- **WHEN** a receive-mode TFTP session progresses through its lifecycle
- **THEN** states transition as: `queued` (command dispatched) → `waiting` (TFTP server listening) → `receiving` (data arriving) → `completed` (transfer done, checksum computed) → `storing` (core persisting to storage) → `stored` (file in final storage)

#### Scenario: Receive-mode failure during transfer
- **WHEN** a receive-mode transfer is interrupted or the file exceeds size limits
- **THEN** the session transitions to `failed` with an error message
- **AND** partial files are discarded

### Requirement: TFTP Serve Mode State Machine
Serve-mode sessions MUST follow the state machine: configuring → queued → staging → ready → serving → completed, with failure transitions to `failed` and timeout/cancel transitions from any active state.

#### Scenario: Serve-mode state progression
- **WHEN** a serve-mode TFTP session progresses through its lifecycle
- **THEN** states transition as: `queued` (staging initiated) → `staging` (image downloading to agent) → `ready` (TFTP server listening for reads) → `serving` (device downloading) → `completed` (transfer done)

#### Scenario: Serve-mode staging failure
- **WHEN** image staging to the agent fails (network error, disk full, etc.)
- **THEN** the session transitions to `failed` with a staging error

### Requirement: TFTP Filename Allowlisting
The TFTP server on the agent MUST reject any request where the filename does not match the pre-configured expected filename for the active session. In receive mode, only matching write requests MUST be accepted. In serve mode, only matching read requests MUST be accepted. The comparison MUST be exact match or configurable glob pattern.

#### Scenario: Authorized filename accepted
- **WHEN** a TFTP client sends a request with a filename matching the session's expected filename
- **THEN** the server accepts the request and begins the transfer

#### Scenario: Unauthorized filename rejected
- **WHEN** a TFTP client sends a request with a filename not matching the session's expected filename
- **THEN** the server rejects the request with a TFTP error packet
- **AND** the rejection is logged as an audit event with the attempted filename

#### Scenario: Wrong mode request rejected
- **WHEN** a TFTP client sends a write request to a serve-mode session or a read request to a receive-mode session
- **THEN** the server rejects the request with a TFTP error packet

### Requirement: TFTP File Size Limits
The agent MUST enforce a configurable maximum file size for TFTP transfers (default 100MB). If an incoming file exceeds the limit in receive mode, the transfer MUST be aborted. In serve mode, oversized images MUST be rejected during staging.

#### Scenario: File within size limit
- **WHEN** a TFTP transfer involves a file within the configured size limit
- **THEN** the transfer completes normally

#### Scenario: Receive file exceeds size limit
- **WHEN** a receive-mode TFTP transfer exceeds the configured maximum file size
- **THEN** the agent aborts the transfer
- **AND** the session transitions to `failed` with a size-limit-exceeded error
- **AND** the partial file is discarded

### Requirement: TFTP Transfer Progress Monitoring
The system SHALL report real-time transfer progress to the UI during active TFTP sessions. Progress MUST be reported via `CommandProgress` messages through the command bus for both receive and serve modes.

#### Scenario: Progress updates during transfer
- **WHEN** a TFTP transfer is in progress (either mode)
- **THEN** the agent sends `CommandProgress` messages at regular intervals
- **AND** each progress message includes bytes transferred, total expected size (if known), and current transfer rate
- **AND** the UI updates the progress display in real-time

#### Scenario: Status heartbeat while waiting
- **WHEN** a TFTP session is in `waiting` or `ready` state
- **THEN** the agent sends periodic status heartbeats (every 5 seconds) confirming the TFTP server is running

### Requirement: TFTP Image Staging for Serve Mode
The system SHALL support staging firmware images from the software library to edge agents for TFTP serving. Images MUST be transferred from core to agent via the gateway's `DownloadFile` gRPC streaming RPC. Staged images MUST have a TTL and MUST be cleaned up after session completion or expiration.

#### Scenario: Image staged to agent
- **WHEN** a serve-mode session is created
- **THEN** the agent calls `DownloadFile` on the gateway to pull the specified image
- **AND** the gateway fetches the image from core-elx and streams it to the agent
- **AND** the agent downloads the image to its local staging directory and verifies the SHA-256 hash
- **AND** the session transitions from `staging` to `ready` when staging completes

#### Scenario: Staged image cleanup
- **WHEN** a serve-mode session completes, expires, or is canceled
- **THEN** the staged image is deleted from the agent's local staging directory

### Requirement: TFTP Session Concurrency Control
The system SHALL enforce a maximum number of concurrent TFTP sessions per agent. The default limit MUST be 1. Attempts to create a session on an agent that has reached its concurrency limit MUST be rejected.

#### Scenario: Concurrent session rejected
- **WHEN** an operator attempts to create a TFTP session on an agent that already has an active session
- **THEN** the system rejects the request with an error indicating the agent is busy

### Requirement: TFTP Security Controls
The TFTP server MUST implement defense-in-depth security. The server MUST bind to a specific interface address (not 0.0.0.0). The server MUST use an unprivileged port by default (6969). All session lifecycle events MUST be logged for audit. File integrity MUST be verified via SHA-256 checksum end-to-end. Serve mode MUST only serve images from the verified software library.

#### Scenario: Server binds to specific interface
- **WHEN** a TFTP session is started on an agent
- **THEN** the TFTP server binds only to the configured address (default: agent's primary interface)
- **AND** the server does NOT bind to 0.0.0.0

#### Scenario: Path traversal prevention
- **WHEN** a TFTP client sends a request with a filename containing path traversal characters (../, /, \, etc.)
- **THEN** the server rejects the request
- **AND** the attempt is logged as a security event

#### Scenario: Serve mode library restriction
- **WHEN** a serve-mode session is created
- **THEN** only images from the verified software library can be served
- **AND** no arbitrary file paths on the agent can be served

#### Scenario: Audit trail
- **WHEN** any TFTP session lifecycle event occurs
- **THEN** the event is persisted with timestamp, actor, session details, and relevant metadata

### Requirement: TFTP Settings UI
The web UI SHALL provide a "Software" tab in the Settings section with sub-tabs for Library, TFTP Sessions, Storage, and Files. The tab MUST be visible only to users with `settings.software.view` or `settings.software.manage` permissions.

#### Scenario: Software tab visibility
- **WHEN** a user with `settings.software.view` permission navigates to Settings
- **THEN** the "Software" tab is visible in the settings navigation

#### Scenario: Receive session creation form
- **WHEN** an operator creates a new receive session
- **THEN** a form is displayed with fields for: target agent (filtered by `tftp` capability), expected filename, storage destination, session timeout, and optional notes

#### Scenario: Serve session creation form
- **WHEN** an operator creates a new serve session
- **THEN** a form is displayed with fields for: target agent (filtered by `tftp` capability), software image (from library), filename to serve as, and session timeout

#### Scenario: Real-time session monitoring
- **WHEN** an active TFTP session is in progress
- **THEN** the UI displays real-time status, progress, bytes transferred, transfer rate, and elapsed time
- **AND** updates are pushed via LiveView PubSub (no polling)

### Requirement: TFTP RBAC Permissions
The system SHALL enforce role-based access control for all TFTP and software operations. Permissions MUST include: `settings.software.manage`, `settings.software.view`, `software.image.upload`, `software.image.delete`, `tftp.session.create`, `tftp.session.cancel`.

#### Scenario: Permission required for session creation
- **WHEN** a user without `tftp.session.create` permission attempts to create a TFTP session
- **THEN** the request is denied with a 403 error

#### Scenario: Permission required for image upload
- **WHEN** a user without `software.image.upload` permission attempts to upload a software image
- **THEN** the request is denied with a 403 error

#### Scenario: View-only access
- **WHEN** a user with `settings.software.view` but without `settings.software.manage` views the Software tab
- **THEN** the user can see session history, library images, and files but cannot create sessions, upload, or delete
