## ADDED Requirements

### Requirement: Admin-Only Access Management
User management actions and authorization settings SHALL be restricted to admin and super_user roles.

#### Scenario: Non-admin denied user management
- **GIVEN** an authenticated user with role "viewer"
- **WHEN** they attempt to create, edit, deactivate, or delete another user
- **THEN** the system SHALL deny the action
- **AND** return a 403 Forbidden response

#### Scenario: Admin can manage users
- **GIVEN** an authenticated user with role "admin"
- **WHEN** they update another user's role
- **THEN** the action SHALL succeed
- **AND** the change SHALL be persisted

### Requirement: Role Mapping from External Claims
The system SHALL support mapping IdP claims or groups to authorization roles and apply the mapping during SSO login.

#### Scenario: Group mapping assigns role
- **GIVEN** a mapping from IdP group "Network Ops" to role "operator"
- **WHEN** a user authenticates via SSO with group "Network Ops"
- **THEN** the system SHALL assign the "operator" role
- **AND** record the mapped role in the user profile

#### Scenario: Default role when no mapping matches
- **GIVEN** a default role of "viewer"
- **WHEN** a user authenticates via SSO with no matching group mappings
- **THEN** the system SHALL assign the default role

### Requirement: Authorization Change Auditing
Authorization-related changes (role updates, user deactivation, mapping edits) SHALL be audit logged.

#### Scenario: Role change audit log
- **GIVEN** an admin updates a user's role
- **WHEN** the change is saved
- **THEN** the system SHALL write an audit event with actor, target user, old role, and new role

#### Scenario: Mapping change audit log
- **GIVEN** an admin creates or deletes a role mapping
- **WHEN** the change is saved
- **THEN** the system SHALL write an audit event with actor and mapping details
