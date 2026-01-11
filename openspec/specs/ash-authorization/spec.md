# ash-authorization Specification

## Purpose
TBD - created by archiving change integrate-ash-framework. Update Purpose after archive.
## Requirements
### Requirement: Actor-Based Authorization
The system SHALL enforce authorization based on the actor (user, API token, or system) performing actions.

#### Scenario: Actor propagation
- **WHEN** a web request is processed
- **THEN** the authenticated user SHALL be set as the actor
- **AND** all Ash actions SHALL receive the actor for policy evaluation

#### Scenario: Anonymous actor handling
- **GIVEN** an unauthenticated request
- **WHEN** accessing a protected resource
- **THEN** the system SHALL deny access
- **AND** return a 401 Unauthorized response

### Requirement: Role-Based Access Control
The system SHALL implement RBAC with roles: super_user, admin, operator, and viewer.

#### Scenario: Super user bypass
- **GIVEN** a user with super_user role
- **WHEN** the user performs any action
- **THEN** all policy checks SHALL be bypassed
- **AND** full access SHALL be granted

#### Scenario: Admin role permissions
- **GIVEN** a user with admin role
- **WHEN** the user accesses resources within their tenant
- **THEN** the user SHALL have full CRUD permissions
- **AND** the user SHALL NOT access other tenants' data

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

### Requirement: Tenant Isolation Policy
All tenant-scoped resources SHALL enforce tenant isolation via Ash policies.

#### Scenario: Cross-tenant access prevention
- **GIVEN** a user belonging to tenant A
- **WHEN** the user attempts to access a resource belonging to tenant B
- **THEN** the system SHALL deny the action
- **AND** log the unauthorized access attempt

#### Scenario: Global resource access
- **GIVEN** a resource with tenant_id = nil (global)
- **WHEN** any authenticated user queries the resource
- **THEN** the resource SHALL be visible
- **AND** tenant isolation SHALL not apply

### Requirement: Partition Isolation Policy
Resources scoped to partitions SHALL enforce partition-based access control.

#### Scenario: Partition-aware device query
- **GIVEN** a user with access to partition P1
- **WHEN** the user queries devices
- **THEN** only devices in partition P1 or with no partition SHALL be returned
- **AND** devices in other partitions SHALL be excluded

### Requirement: Field-Level Authorization
Sensitive fields SHALL be protected by field-level policies.

#### Scenario: Hidden sensitive field
- **GIVEN** a viewer role user
- **WHEN** the user queries a user resource
- **THEN** the hashed_password field SHALL be returned as %Ash.ForbiddenField{}
- **AND** the email field SHALL be visible

### Requirement: Authorization Audit Logging
Authorization failures SHALL be logged for security monitoring.

#### Scenario: Policy violation logging
- **WHEN** an authorization policy denies an action
- **THEN** the system SHALL log the actor, action, resource, and reason
- **AND** the log entry SHALL include timestamp and request ID

