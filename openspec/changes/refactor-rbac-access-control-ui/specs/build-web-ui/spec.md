## ADDED Requirements
### Requirement: RBAC Policy Editor Dashboard
The web-ng UI SHALL provide an admin-only RBAC policy editor dashboard at `/settings/auth/access` that allows configuring role mappings, role profiles, and per-profile permissions on a single page.

#### Scenario: Admin opens the Access Control dashboard
- **GIVEN** an authenticated admin user with `settings.rbac.manage`
- **WHEN** they navigate to `/settings/auth/access`
- **THEN** the page SHALL display role profile cards (viewer, operator, admin, plus any custom profiles)
- **AND** the page SHALL display role mapping configuration (default role and IdP claim rules) without leaving the page

### Requirement: Profile Cards Are Horizontally Stacked
The RBAC policy editor dashboard SHALL present each role profile as a separate card in a horizontally scrollable strip, optimized for rapid side-by-side scanning.

#### Scenario: Admin views multiple profiles
- **GIVEN** three built-in profiles and two custom profiles exist
- **WHEN** the admin opens the dashboard
- **THEN** five profile cards SHALL be visible in a horizontally scrollable container
- **AND** each card header SHALL indicate whether the profile is built-in or custom

### Requirement: Per-Profile Permissions Grid
Each profile card SHALL include a permissions grid with checkbox controls that allows editing permissions for that specific profile.

#### Scenario: Admin toggles a permission via the grid
- **GIVEN** a custom profile card is visible
- **WHEN** the admin checks a permission checkbox in that profile card
- **THEN** the profile card SHALL indicate unsaved changes
- **AND** saving the profile SHALL persist the permission set

### Requirement: Grid Layout Uses Resources (Columns) and Actions (Rows)
The permissions grid within each profile card SHALL be rendered as a table where resources are columns and actions are rows. Each cell SHALL represent whether the profile grants the `{resource}.{action}` permission.

#### Scenario: Admin scans permissions like a policy editor
- **GIVEN** the permission catalog includes resources `devices` and `settings.auth`
- **AND** actions include `view`, `create`, `update`, `delete`, and `manage`
- **WHEN** the admin views any profile card
- **THEN** the grid SHALL show `devices` and `settings.auth` as column headers
- **AND** the grid SHALL show actions as row labels
- **AND** checking a cell SHALL toggle only that `{resource}.{action}` permission for that profile

### Requirement: Built-In Profiles Are Clone-Only
Built-in role profiles MUST be displayed in the dashboard but MUST NOT be directly editable. Built-in profiles SHALL be clonable to create a custom profile.

#### Scenario: Admin attempts to edit a built-in profile
- **GIVEN** the admin is viewing the built-in "viewer" profile card
- **WHEN** they attempt to toggle any permission checkbox
- **THEN** the checkbox controls MUST be disabled
- **AND** the UI SHALL offer a "Clone" action to create a custom profile based on "viewer"

### Requirement: Minimal Help, No Persistent Legend
The RBAC policy editor dashboard MUST NOT render a persistent legend block. Explanatory content SHALL be provided via concise inline copy and optional contextual help.

#### Scenario: Admin needs clarification
- **GIVEN** an admin is editing permissions
- **WHEN** they request help (for example by clicking a help icon)
- **THEN** the UI SHALL show a brief explanation of roles vs profiles and assignment precedence
- **AND** the explanation MUST NOT permanently consume page real estate when not in use
