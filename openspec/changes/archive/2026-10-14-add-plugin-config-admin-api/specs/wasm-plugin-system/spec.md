## ADDED Requirements

### Requirement: Plugin assignment JSON identity
The `/api/admin/plugin-assignments` JSON API SHALL include `plugin_id` on every assignment object it returns, and SHALL expose `GET /api/admin/plugin-assignments/{id}` for a single assignment, using the same authentication and `plugins.view` / `plugins.assign` permissions as the existing list/create/update/delete routes.

#### Scenario: List includes plugin_id
- **GIVEN** an enabled assignment of package `netbox-inventory` to an agent
- **WHEN** an authorized caller GET `/api/admin/plugin-assignments`
- **THEN** that assignment object SHALL include `plugin_id` `netbox-inventory`

#### Scenario: Get one assignment
- **GIVEN** an assignment id returned by create or list
- **WHEN** an authorized caller GET `/api/admin/plugin-assignments/{id}`
- **THEN** the system SHALL return that assignment
- **AND** SHALL NOT include secret values inside `params`
