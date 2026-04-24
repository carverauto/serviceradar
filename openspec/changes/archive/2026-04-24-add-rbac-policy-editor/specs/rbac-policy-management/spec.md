## ADDED Requirements
### Requirement: Permission Catalog for RBAC
The system SHALL expose a canonical permission catalog organized by section (analytics, devices, services, observability, settings) and action (view, create, update, delete, manage, execute). The catalog SHALL be action-level and serve as the single source used by UI rendering and API authorization.

#### Scenario: Admin loads the RBAC editor
- **GIVEN** an authenticated admin
- **WHEN** they open the RBAC policy editor
- **THEN** the UI SHALL display the full permission catalog grouped by section and action
- **AND** each permission SHALL have a stable key for evaluation

### Requirement: Role Profiles (Built-in and Custom)
The system SHALL provide built-in role profiles (admin, operator, viewer) and allow admins to create, edit, and assign custom role profiles. Built-in profiles MUST be clonable but NOT editable. Custom profiles MUST be uniquely named and persistable.

#### Scenario: Create and assign a custom profile
- **GIVEN** an authenticated admin
- **WHEN** they create a custom profile "Ops Read Only" with read-only permissions
- **AND** assign it to a user
- **THEN** the user SHALL inherit the profile's permissions
- **AND** the assignment SHALL persist across sessions

### Requirement: Consistent UI and API Enforcement
RBAC decisions SHALL be enforced consistently across UI and API. Unauthorized actions MUST be hidden or disabled in the UI and MUST be rejected at the API layer.

#### Scenario: Viewer cannot see or invoke delete
- **GIVEN** a viewer user
- **WHEN** they view the Devices list
- **THEN** bulk delete controls SHALL NOT be visible
- **AND** a delete API request SHALL return 403 Forbidden

### Requirement: RBAC Policy Editor UI
The system SHALL provide an admin-only RBAC editor UI that displays a matrix of permissions (rows) and role profiles (columns), supports search/filtering, and allows saving changes with confirmation.

#### Scenario: Admin edits permissions in the matrix
- **GIVEN** an authenticated admin in the RBAC editor
- **WHEN** they toggle the "devices.delete" permission for a custom profile
- **THEN** the UI SHALL mark the profile as having unsaved changes
- **AND** saving SHALL persist the updated permission set
