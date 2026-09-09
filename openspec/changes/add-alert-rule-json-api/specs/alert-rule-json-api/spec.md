## ADDED Requirements

### Requirement: StatefulAlertRule JSON:API Provisioning
The system SHALL expose `StatefulAlertRule` create, read, update, and
destroy operations over the existing Ash JSON:API surface, authorized by
the same operator/admin/system role policy that governs it today.

#### Scenario: An operator-role actor creates an alert rule via the API
- **WHEN** an actor with `operator`, `admin`, or `system` role sends
  `POST /api/v2/stateful-alert-rules` with a valid rule definition
- **THEN** the rule SHALL be created exactly as if authored through the
  existing Settings rules UI

#### Scenario: A non-operator actor is denied
- **WHEN** an actor without `operator`, `admin`, or `system` role attempts
  `POST`, `PATCH`, or `DELETE` against `/api/v2/stateful-alert-rules`
- **THEN** the request SHALL be denied, matching the resource's existing
  policy for those actions

#### Scenario: Reading rules requires no new access model
- **WHEN** any actor sends `GET /api/v2/stateful-alert-rules` or
  `GET /api/v2/stateful-alert-rules/active`
- **THEN** results SHALL be scoped exactly as the resource's existing read
  policy already scopes them

### Requirement: Sibling Preset-Rule Resources Remain Unexposed
Adding JSON:API routes to `StatefulAlertRule` SHALL NOT add JSON:API routes
to `StatefulAlertRuleTemplate`, `LogPromotionRule`, or
`LogPromotionRuleTemplate`, which share its underlying resource macro.

#### Scenario: Sibling resources have zero routes
- **WHEN** the Observability domain is mounted on the JSON:API router
- **THEN** `StatefulAlertRuleTemplate`, `LogPromotionRule`, and
  `LogPromotionRuleTemplate` SHALL each report zero JSON:API routes

### Requirement: OpenAPI Surfaces Stay in Sync
The system SHALL keep both OpenAPI surfaces — the committed
`priv/static/openapi.json` and the live `/api/v2/open_api` document — in
sync with the new `stateful-alert-rules` routes and every other route newly
reachable through mounting the Observability domain.

#### Scenario: Committed OpenAPI document includes the new route
- **WHEN** `mix serviceradar.openapi.dump --check` is run after this change
- **THEN** it SHALL report no drift

#### Scenario: Live OpenAPI document includes the new route
- **WHEN** an authenticated request is made to `GET /api/v2/open_api`
- **THEN** the response SHALL include `/api/v2/stateful-alert-rules` under
  its `paths`
