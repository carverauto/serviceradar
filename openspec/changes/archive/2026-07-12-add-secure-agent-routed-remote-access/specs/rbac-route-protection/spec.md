## ADDED Requirements
### Requirement: Remote access requires explicit authorization
Remote-access APIs, channels, and session attach paths SHALL require explicit RBAC permissions distinct from read-only device visibility.

#### Scenario: Device viewer cannot open shell
- **GIVEN** a user can view a device details page
- **AND** the user lacks remote-access permission
- **WHEN** the user attempts to create or attach to a remote-access session
- **THEN** the request SHALL be denied
- **AND** no session grant SHALL be issued.

### Requirement: Privileged remote access may require approval
Remote-access policy SHALL support approval requirements for sensitive targets, credential modes, or roles.

#### Scenario: Approval required for broad SSH credential
- **GIVEN** a credential rule is marked as requiring approval
- **WHEN** an operator requests a session using that credential rule
- **THEN** no session, attach ticket, or credential grant SHALL be issued until an authorized approver approves the separate access request
- **AND** the access request SHALL expire if not approved before its deadline.

### Requirement: Remote access authorization is rechecked on attach
The system SHALL recheck authorization when a browser attaches or reattaches to an existing remote-access session.

#### Scenario: Revoked user cannot reattach
- **GIVEN** a user opened a remote-access session
- **AND** the user's remote-access permission is revoked
- **WHEN** the user attempts to reattach after disconnecting
- **THEN** the attach request SHALL be denied
- **AND** the denial SHALL be audited.
