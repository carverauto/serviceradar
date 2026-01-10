# SRQL Spec Deltas

## ADDED Requirements

### Requirement: Tenant Context Propagation

The SRQL service SHALL propagate tenant context from the caller to Ash queries for resources that require tenant isolation.

#### Scenario: Tenant-scoped query with authenticated user
- **GIVEN** an authenticated user with tenant_id "tenant-123"
- **WHEN** a client sends a query with `actor` option set to the user
- **THEN** SRQL passes the tenant context to Ash
- **AND** results are filtered to only include records from tenant-123

#### Scenario: Tenant-scoped query without actor fails hard
- **GIVEN** a query for a tenant-scoped entity (services, gateways, devices)
- **WHEN** a client sends a query without providing an actor
- **THEN** SRQL MUST return an error indicating tenant context is required
- **AND** no data is returned
- **AND** the error is logged for security audit purposes

#### Scenario: Non-tenant-scoped query works without actor
- **GIVEN** a query for a non-tenant-scoped entity (logs, otel_metrics)
- **WHEN** a client sends a query without providing an actor
- **THEN** SRQL executes the query successfully
- **AND** returns results without tenant filtering

### Requirement: Time Filter Serialization

The SRQL Rust NIF SHALL correctly serialize all time filter variants when encoding the parsed AST.

#### Scenario: RelativeHours serialization
- **GIVEN** a query with `time:last_1h` filter
- **WHEN** the SRQL NIF parses and serializes the AST
- **THEN** the TimeFilterSpec::RelativeHours variant serializes correctly
- **AND** the query executes without serialization errors

#### Scenario: RelativeDays serialization
- **GIVEN** a query with `time:last_7d` filter
- **WHEN** the SRQL NIF parses and serializes the AST
- **THEN** the TimeFilterSpec::RelativeDays variant serializes correctly
- **AND** the query executes without serialization errors

#### Scenario: AbsoluteRange serialization
- **GIVEN** a query with explicit date range `time:2024-01-01..2024-01-31`
- **WHEN** the SRQL NIF parses and serializes the AST
- **THEN** the TimeFilterSpec::AbsoluteRange variant serializes correctly
- **AND** the query executes without serialization errors

### Requirement: Services Entity Query Support

The SRQL service SHALL support querying the `services` entity which maps to ServiceCheck records with proper tenant isolation and field mapping.

#### Scenario: Basic services query
- **GIVEN** an authenticated user with service checks in their tenant
- **WHEN** a client sends `in:services time:last_1h sort:timestamp:desc`
- **THEN** SRQL returns service check records for the user's tenant
- **AND** the `timestamp` field maps to `last_check_at`
- **AND** the `service_name` field maps to `name`
- **AND** the `service_type` field maps to `check_type`

#### Scenario: Services query with availability filter
- **GIVEN** an authenticated user with both passing and failing service checks
- **WHEN** a client sends `in:services available:false time:last_1h`
- **THEN** SRQL returns only service checks with failing status
- **AND** results are filtered to the user's tenant

#### Scenario: Services query by type
- **GIVEN** an authenticated user with multiple check types (ping, http, tcp)
- **WHEN** a client sends `in:services service_type:http time:last_1h`
- **THEN** SRQL returns only HTTP service checks
- **AND** results are filtered to the user's tenant
