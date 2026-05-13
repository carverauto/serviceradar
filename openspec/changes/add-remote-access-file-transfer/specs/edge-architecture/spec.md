## ADDED Requirements
### Requirement: Remote access file transfer is route-bound and policy-controlled
ServiceRadar SHALL provide SFTP-style file transfer through the existing remote-access selected-agent route without allowing clients to choose arbitrary routes, target hosts, credential rules, custody modes, recording policies, quotas, or approval overrides.

#### Scenario: Browser submits only transfer intent
- **GIVEN** an authenticated user requests a remote-access file operation
- **WHEN** the request reaches the browser/API boundary
- **THEN** the accepted fields SHALL be limited to target or session reference, operation, direction, path intent, optional destination path, and display metadata
- **AND** ServiceRadar SHALL derive route, selected agent, gateway, target host, credential mode, credential rule, recording policy, quota, content-audit policy, and approval requirements from trusted inventory, policy, and session state.

#### Scenario: Client attempts to override trusted policy
- **GIVEN** a file-transfer request includes client-supplied route, agent, gateway, target host, credential rule, custody, recording, content-audit, approval, or quota fields
- **WHEN** ServiceRadar validates the request
- **THEN** the request SHALL be rejected before any gateway or agent frame is emitted
- **AND** the denial SHALL be audited without exposing credentials or file contents.

### Requirement: File transfer enforces per-operation RBAC and approval
ServiceRadar SHALL authorize file transfer by operation and SHALL support approval gates for sensitive transfers before the selected agent opens or mutates a target file.

#### Scenario: User lacks operation permission
- **GIVEN** a user has remote SSH access to a target but lacks `devices.remote_access.files.download`
- **WHEN** the user requests a download
- **THEN** ServiceRadar SHALL deny the transfer before dispatch to the selected agent
- **AND** the denial SHALL identify the operation and target in audit metadata without recording file contents.

#### Scenario: Sensitive path requires approval
- **GIVEN** policy marks a path or operation as approval-required
- **WHEN** a user requests that transfer without a matching unexpired approval
- **THEN** ServiceRadar SHALL create or require an approval workflow according to policy
- **AND** SHALL NOT issue a transfer grant until approval matches actor, target, route, operation, path policy, and expiry.

### Requirement: File transfer path and quota policy fail closed
The selected agent SHALL enforce path and quota policy locally before and during target file operations.

#### Scenario: Path cannot be validated
- **GIVEN** a transfer policy defines path allow/deny rules, root containment, or symlink behavior
- **WHEN** the agent cannot normalize the requested path or verify the symlink/realpath behavior required by policy
- **THEN** the agent SHALL fail the transfer before opening or mutating the file
- **AND** SHALL return a sanitized policy failure.

#### Scenario: Quota is exhausted during transfer
- **GIVEN** a transfer has byte, file-count, recursive-depth, rate, or concurrent-transfer limits
- **WHEN** the operation would exceed a configured limit
- **THEN** the selected agent SHALL stop the transfer
- **AND** ServiceRadar SHALL record a quota-exhausted outcome with byte/file counters and without persisted file contents.

### Requirement: File transfer recording stores metadata by default
ServiceRadar SHALL record file-transfer lifecycle metadata for audit and replay while avoiding file-content persistence unless an explicit content-audit artifact policy enables it.

#### Scenario: Download completes
- **WHEN** a download completes successfully
- **THEN** ServiceRadar SHALL record transfer ID, actor, target, selected route, operation, direction, redacted path or path hash according to policy, byte count, file count, status, timestamps, and retention expiry
- **AND** SHALL NOT store downloaded file bytes in audit, replay, recording events, or exports by default.

#### Scenario: Content artifact retention is enabled
- **GIVEN** an explicit content-audit policy enables artifact retention for a transfer class
- **WHEN** a matching transfer runs
- **THEN** ServiceRadar MAY retain a sensitive artifact reference with retention and export controls
- **AND** export SHALL require a dedicated file-transfer export permission.

### Requirement: SFTP is the first-class implementation model
ServiceRadar SHALL implement structured SFTP operations first and SHALL defer SCP compatibility until SCP maps into the same policy, quota, recording, and audit manager.

#### Scenario: SFTP adapter is available
- **WHEN** an agent advertises `remote_access.sftp`
- **THEN** it SHALL be able to enforce operation, path, symlink, quota, cancellation, audit, and recording policy locally
- **AND** it SHALL reuse the existing SSH credential custody and host-key trust paths.

#### Scenario: SCP support is requested before policy parity exists
- **WHEN** SCP compatibility would bypass structured operation authorization, quota enforcement, or recording events
- **THEN** ServiceRadar SHALL keep `remote_access.scp` unavailable
- **AND** SHALL direct callers to the SFTP transfer path.
