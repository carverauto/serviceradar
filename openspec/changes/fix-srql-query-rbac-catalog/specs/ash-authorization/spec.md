## ADDED Requirements

### Requirement: SRQL entity queries require the matching RBAC view permission
The system SHALL refuse an SRQL query whose `in:<entity>` maps to an RBAC
catalog view key the caller does not hold. The check SHALL run on the shared
execute path used by `POST /api/query`, LiveView SRQL (`SRQL.Page` /
`query_request`), dashboard frame execution, and MCP `execute_srql`. The
check SHALL use `current_scope` and `ServiceRadarWebNG.RBAC.can?/2`. It MUST
NOT translate SRQL into Ash.Query and MUST NOT treat this as tenant
isolation.

#### Scenario: Custom profile cannot query devices
- **GIVEN** an authenticated user whose custom role profile omits `devices.view`
- **WHEN** the user runs `in:devices` on `POST /api/query`
- **THEN** the response is HTTP 403
- **AND** no device rows are returned

#### Scenario: Custom profile cannot query logs
- **GIVEN** an authenticated user whose custom role profile omits `observability.logs.view`
- **WHEN** the user runs `in:logs` on `POST /api/query`
- **THEN** the response is HTTP 403

#### Scenario: Built-in viewer can still query devices
- **GIVEN** a user with the built-in viewer role
- **WHEN** the user runs `in:devices` on `POST /api/query`
- **THEN** the query is authorized at the catalog gate
- **AND** results are returned according to the existing SRQL compiler

#### Scenario: Dashboards stay on Ash/scope search
- **GIVEN** an authenticated user
- **WHEN** the user runs `in:dashboards`
- **THEN** the catalog view-key gate does not 403 the request
- **AND** dashboard search still uses the existing Ash/scope path

#### Scenario: Scope is not dropped
- **GIVEN** `Api.Access.execute_query/2` is invoked
- **WHEN** it forwards the request to SRQL
- **THEN** the request map includes the caller's `current_scope`
- **AND** a regression test fails if that key is omitted
