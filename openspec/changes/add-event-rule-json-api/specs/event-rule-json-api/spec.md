## ADDED Requirements

### Requirement: EventRule JSON:API Provisioning
The system SHALL expose `EventRule` create, read, update, and destroy
operations over the existing Ash JSON:API surface at `/api/v2/event-rules`,
authorized by the same role policy that governs it today (viewer+ read,
operator+ write).

#### Scenario: An operator-role actor creates a log promotion rule via the API
- **WHEN** an actor with `operator`, `admin`, or `system` role sends
  `POST /api/v2/event-rules` with a valid rule definition
- **THEN** the rule SHALL be created exactly as if authored through the
  existing Settings → Events UI, and SHALL be visible to
  `LogPromotion.active_log_rules/0` on the next cache refresh

#### Scenario: A non-operator actor is denied write access
- **WHEN** an actor without `operator`, `admin`, or `system` role attempts
  `POST`, `PATCH`, or `DELETE` against `/api/v2/event-rules`
- **THEN** the request SHALL be denied, matching the resource's existing
  policy for those actions

#### Scenario: Reading rules requires viewer or higher
- **WHEN** any authenticated actor sends `GET /api/v2/event-rules` or
  `GET /api/v2/event-rules/active`
- **THEN** results SHALL be scoped exactly as the resource's existing read
  policy already scopes them

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
