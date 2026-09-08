## MODIFIED Requirements
### Requirement: Role-Based Access Control
The system SHALL implement RBAC using built-in roles (admin, operator, viewer) and custom role profiles. Authorization decisions MUST be evaluated against the effective role profile for the actor, with built-in roles mapped to system profiles that preserve current default permissions.

#### Scenario: Admin role permissions
- **GIVEN** a user assigned to the admin role profile
- **WHEN** the user accesses resources within the deployment
- **THEN** the user SHALL have full CRUD permissions
- **AND** the user SHALL NOT access data outside the deployment scope

#### Scenario: Custom profile restricts destructive actions
- **GIVEN** a custom role profile that allows read and update but denies delete
- **AND** a user is assigned to that profile
- **WHEN** the user attempts to delete a device
- **THEN** the system SHALL deny the action
- **AND** return a 403 Forbidden response
