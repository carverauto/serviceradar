## ADDED Requirements

### Requirement: User Directory
The system SHALL provide an admin-visible user directory with filterable user status, role, and authentication method.

#### Scenario: List users
- **GIVEN** an authenticated admin
- **WHEN** they request the user directory
- **THEN** the system SHALL return users with id, name, email, role, status, auth method, and last login

#### Scenario: Filter by status
- **GIVEN** an authenticated admin
- **WHEN** they filter by status "inactive"
- **THEN** the directory SHALL return only inactive users

### Requirement: User Lifecycle Management
The system SHALL allow admins to create users, update profiles, change roles, and deactivate/reactivate accounts.

#### Scenario: Create a local user
- **GIVEN** an authenticated admin
- **WHEN** they create a user with name, email, and role
- **THEN** the system SHALL create the user in active status
- **AND** issue an invite or password setup flow

#### Scenario: Deactivate a user
- **GIVEN** an authenticated admin
- **WHEN** they deactivate a user account
- **THEN** the user status SHALL be set to inactive
- **AND** the user SHALL be prevented from authenticating

#### Scenario: Reactivate a user
- **GIVEN** a previously deactivated user
- **WHEN** an admin reactivates the account
- **THEN** the user status SHALL return to active

### Requirement: Session and Token Revocation
Deactivating a user SHALL revoke active sessions and API tokens to prevent continued access.

#### Scenario: Revoke sessions on deactivation
- **GIVEN** an active user with valid sessions and API tokens
- **WHEN** an admin deactivates the user
- **THEN** existing sessions and tokens SHALL be revoked
- **AND** subsequent requests with those tokens SHALL be rejected
