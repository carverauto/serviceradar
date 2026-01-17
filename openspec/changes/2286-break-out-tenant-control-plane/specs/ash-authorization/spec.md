# ash-authorization Specification Deltas

## MODIFIED Requirements

### Requirement: Role-Based Access Control

The system SHALL implement RBAC with roles: admin, operator, viewer, and system.

#### Scenario: Admin role permissions
- **GIVEN** a user with admin role
- **WHEN** the user accesses resources within their deployment
- **THEN** the user SHALL have full CRUD permissions
- **AND** the user SHALL NOT access data outside the deployment

#### Scenario: Operator role permissions
- **GIVEN** a user with operator role
- **WHEN** the user attempts to modify resources
- **THEN** the user SHALL be able to create and update resources
- **AND** the user SHALL NOT be able to delete resources

#### Scenario: Viewer role permissions
- **GIVEN** a user with viewer role
- **WHEN** the user attempts to modify resources
- **THEN** the action SHALL be denied
- **AND** the user SHALL only have read access

#### Scenario: System role for background operations
- **GIVEN** a SystemActor with system role
- **WHEN** the actor performs operations within instance context
- **THEN** the system role SHALL bypass user-level policies
- **AND** the actor SHALL still be restricted to the instance database search_path

## ADDED Requirements

### Requirement: SystemActor Authorization Pattern

Background operations SHALL use the SystemActor pattern for authorization instead of bypassing policies.

#### Scenario: Instance-scoped SystemActor
- **WHEN** background operation needs to access instance data
- **THEN** the operation creates SystemActor with system(component_name)
- **AND** the actor has role: :system
- **AND** the operation passes actor to all Ash operations

#### Scenario: No hardcoded system actors in web-ng
- **WHEN** web-ng code needs system-level authorization
- **THEN** the code imports ServiceRadar.Actors.SystemActor
- **AND** the code does NOT define local system_actor functions
- **AND** the code does NOT use hardcoded @system_actor module attributes
