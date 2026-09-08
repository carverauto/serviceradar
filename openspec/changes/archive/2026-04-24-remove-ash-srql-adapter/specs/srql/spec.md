# SRQL Spec Delta: Remove Ash Adapter

## REMOVED Requirements

### Requirement: Ash adapter routing for SRQL queries
The SRQL module SHALL NOT route queries through an Ash adapter layer. All SRQL queries use the direct Rust NIF → SQL execution path.

#### Scenario: All queries use SQL path
- **GIVEN** any SRQL query for any entity
- **WHEN** the query is executed via `ServiceRadarWebNG.SRQL.query/2`
- **THEN** the query is processed by the Rust NIF and executed as raw SQL via Ecto
- **AND** no Ash resources are involved in the read path

#### Scenario: No feature flag for query routing
- **GIVEN** the SRQL module configuration
- **WHEN** checking for routing behavior
- **THEN** there is no `ash_srql_adapter` feature flag
- **AND** there is only one execution path (SQL via Rust NIF)

## MODIFIED Requirements

### Requirement: SRQL query execution path
The SRQL service SHALL execute all queries through the Rust NIF which generates parameterized SQL, then execute that SQL directly via Ecto adapters.

#### Scenario: Standard query execution
- **GIVEN** a valid SRQL query like `in:devices hostname:%server%`
- **WHEN** the query is executed
- **THEN** the Rust NIF translates it to parameterized SQL
- **AND** Ecto.Adapters.SQL.query executes the SQL
- **AND** results are formatted and returned

#### Scenario: Boolean field filtering
- **GIVEN** a query with a boolean filter like `in:devices is_available:true`
- **WHEN** the query is executed
- **THEN** the Rust NIF generates correct SQL with boolean parameter binding
- **AND** no Elixir-side type conversion is needed

#### Scenario: Array field filtering
- **GIVEN** a query with an array filter like `in:devices discovery_sources:(sweep)`
- **WHEN** the query is executed
- **THEN** the Rust NIF generates SQL with PostgreSQL array containment (`@>`)
- **AND** no Elixir-side array handling is needed

#### Scenario: LIKE operator on text fields
- **GIVEN** a query with LIKE pattern like `in:devices hostname:%faker%`
- **WHEN** the query is executed
- **THEN** the Rust NIF generates SQL with ILIKE operator
- **AND** results include matching rows

### Requirement: Authentication enforcement at endpoint level
Read access to SRQL query results SHALL be enforced at the LiveView/API endpoint level, not through Ash policies.

#### Scenario: LiveView requires authentication
- **GIVEN** an unauthenticated user
- **WHEN** they attempt to access a LiveView that uses SRQL
- **THEN** they are redirected to login
- **AND** no SRQL query is executed

#### Scenario: API requires JWT
- **GIVEN** an API request without a valid JWT
- **WHEN** the request attempts to query SRQL
- **THEN** the request is rejected with 401 Unauthorized
- **AND** no SRQL query is executed

#### Scenario: Authenticated users can query
- **GIVEN** an authenticated user with any role
- **WHEN** they execute an SRQL query
- **THEN** the query is executed
- **AND** results are returned
