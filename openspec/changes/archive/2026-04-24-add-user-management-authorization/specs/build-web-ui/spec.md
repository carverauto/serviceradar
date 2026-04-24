## ADDED Requirements

### Requirement: Auth Settings Navigation
The Settings navigation SHALL include an "Auth" section with "Users" and "Authorization" tabs for admin-only access management.

#### Scenario: Auth settings entry visible to admins
- **GIVEN** an authenticated admin user
- **WHEN** they view Settings navigation
- **THEN** an "Auth" entry SHALL be visible
- **AND** it SHALL link to `/settings/auth/users` by default

#### Scenario: Auth settings entry hidden for non-admins
- **GIVEN** an authenticated user without admin or super_user role
- **WHEN** they view Settings navigation
- **THEN** the "Auth" entry SHALL NOT be visible

### Requirement: User Management UI
The UI SHALL provide a Users tab to list and manage user accounts, including role changes and activation status.

#### Scenario: Admin views user directory
- **GIVEN** an authenticated admin on `/settings/auth/users`
- **WHEN** the page loads
- **THEN** the UI SHALL display a table of users with name, email, role, status, auth method, and last login
- **AND** the table SHALL support search by name or email

#### Scenario: Admin updates user role
- **GIVEN** an admin viewing a user row
- **WHEN** they change the user's role to "operator"
- **THEN** the UI SHALL confirm the change
- **AND** the updated role SHALL appear in the table

#### Scenario: Admin deactivates a user
- **GIVEN** an admin viewing a user row
- **WHEN** they click "Deactivate"
- **THEN** the UI SHALL show a confirmation dialog
- **AND** upon confirmation, the user SHALL be marked inactive in the table

### Requirement: Authorization Settings UI
The UI SHALL allow admins to manage default role and IdP claim/group mappings that drive role assignment.

#### Scenario: Admin sets default role
- **GIVEN** an admin on `/settings/auth/authorization`
- **WHEN** they select "viewer" as the default role and save
- **THEN** the UI SHALL show a success state
- **AND** the saved default role SHALL display on reload

#### Scenario: Admin maps IdP group to role
- **GIVEN** an admin on the authorization settings page
- **WHEN** they add a mapping from group "Network Ops" to role "operator"
- **THEN** the mapping SHALL appear in the list
- **AND** the UI SHALL allow editing or removing the mapping
