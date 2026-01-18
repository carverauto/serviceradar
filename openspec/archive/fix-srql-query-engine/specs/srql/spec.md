# SRQL Spec Delta: Fix Query Engine

## MODIFIED Requirements

### Requirement: Filter Operations

The SRQL query engine SHALL support the following filter operations through both SQL and Ash query paths:

- **eq** - Exact equality match
- **neq** - Not equal
- **gt/gte/lt/lte** - Comparison operators
- **like** - Case-insensitive substring matching with `%` wildcards
- **not_like** - Negated substring matching
- **in** - Value in list
- **not_in** - Value not in list
- **contains** - Array contains value(s)

#### Scenario: LIKE filter on text field
- **GIVEN** a query `in:devices ip:%172.16.80%`
- **WHEN** the query is executed through the Ash adapter
- **THEN** devices with IP addresses containing "172.16.80" SHALL be returned
- **AND** the match SHALL be case-insensitive

#### Scenario: LIKE filter on hostname
- **GIVEN** a query `in:devices hostname:%faker%`
- **WHEN** the query is executed
- **THEN** devices with hostnames containing "faker" SHALL be returned

#### Scenario: Array field filter
- **GIVEN** a query `in:devices discovery_sources:(sweep)`
- **WHEN** the query is executed through the Ash adapter
- **THEN** devices where `discovery_sources` array contains "sweep" SHALL be returned
- **AND** no PostgreSQL operator error SHALL occur

### Requirement: Entity Token Required

All SRQL queries SHALL include an `in:<entity>` token to specify the target entity.

#### Scenario: Quick filter includes entity token
- **GIVEN** a user clicks the "Swept" quick filter on the devices page
- **WHEN** the filter URL is generated
- **THEN** the query SHALL be `in:devices discovery_sources:(sweep)`
- **AND** the query SHALL NOT be `discovery_sources:sweep` (missing entity)

#### Scenario: Missing entity token error
- **GIVEN** a query without an entity token like `is_available:true`
- **WHEN** the query is parsed
- **THEN** an error "queries must include an in:<entity> token" SHALL be returned

### Requirement: Time Filter Serialization

The SRQL parser SHALL correctly serialize all TimeFilterSpec variants to JSON for the NIF boundary.

#### Scenario: RelativeHours serialization
- **GIVEN** a query `in:devices time:last_24h`
- **WHEN** the query AST is serialized to JSON
- **THEN** the time_filter SHALL serialize to `{"type": "relative_hours", "value": 24}`
- **AND** no serialization error SHALL occur

#### Scenario: RelativeDays serialization
- **GIVEN** a query `in:devices time:last_7d`
- **WHEN** the query AST is serialized to JSON
- **THEN** the time_filter SHALL serialize to `{"type": "relative_days", "value": 7}`
- **AND** no serialization error SHALL occur

## REMOVED Requirements

### Requirement: Tenant Context Propagation

**Reason**: Multi-tenancy has been removed from ServiceRadar. Tenant isolation is no longer required.

**Migration**: Remove tenant context extraction from Ash adapter. All queries operate on the single deployment schema.
