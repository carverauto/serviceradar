## ADDED Requirements

### Requirement: EventRule JSON:API Provisioning
The system SHALL expose `EventRule` create, read, update, and destroy
operations over the existing Ash JSON:API surface at `/api/v2/event-rules`,
authorized by the existing `observability.rules.view`, `.create`, `.update`,
and `.delete` permissions for the corresponding operations. Custom profiles
SHALL grant or revoke these permissions independently of the user's base role.
Built-in viewer read and operator write defaults and trusted system access
SHALL remain supported.

#### Scenario: An authorized actor creates a log promotion rule via the API
- **WHEN** an actor with `observability.rules.create` permission sends
  `POST /api/v2/event-rules` with a valid rule definition
- **THEN** the rule SHALL be created exactly as if authored through the
  existing Settings -> Events UI, and SHALL be visible to
  `LogPromotion.active_log_rules/0` on the next read without waiting for
  cache expiry or manually invalidating the cache

#### Scenario: A custom operator profile revokes a write permission
- **WHEN** an operator's configured profile lacks the permission corresponding
  to `POST`, `PATCH`, or `DELETE` against `/api/v2/event-rules`
- **THEN** that operation SHALL be denied without creating, modifying, or
  deleting a rule, even if other rule permissions remain granted

#### Scenario: A custom viewer profile grants a targeted write permission
- **WHEN** a viewer's configured profile grants `observability.rules.create`,
  `.update`, or `.delete`
- **THEN** the corresponding API operation SHALL succeed for a valid request
  without requiring an operator role, view permission, or unrelated write
  permissions

#### Scenario: Reading rules honors the configured view permission
- **WHEN** an authenticated actor requests the rule list, active rules, or a
  rule by ID
- **THEN** the resource SHALL require `observability.rules.view`, including
  grants to viewers and revocations from operators
- **AND** a profile update SHALL affect subsequent authenticated requests
  without requiring a new bearer token

#### Scenario: Rule permissions do not authorize profile management
- **WHEN** a viewer or operator has rule permissions but lacks
  `settings.rbac.manage`
- **THEN** profile API mutations and access to the RBAC profile editor SHALL
  remain denied under the existing admin permission boundary

#### Scenario: Unauthenticated read returns empty
- **WHEN** an unauthenticated request is sent to `GET /api/v2/event-rules`
- **THEN** the response SHALL be a valid JSON:API document with an empty
  `data` array

### Requirement: OpenAPI Document Stays in Sync
The committed `priv/static/openapi.json` SHALL include
`/event-rules` as a router-relative path under the `/api/v2` mount after
this change.

#### Scenario: Committed OpenAPI document includes the new route
- **WHEN** `mix serviceradar.openapi.dump --check` is run after this change
- **THEN** it SHALL report no drift
