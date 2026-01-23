## ADDED Requirements

### Requirement: SRQL builder automatically uses list syntax for array fields
The SRQL query builder SHALL automatically wrap values for array-type fields in list syntax, regardless of whether the user enters a single value or multiple values.

#### Scenario: Single value for array field
- **GIVEN** `discovery_sources` is configured as an array field in the SRQL Catalog
- **WHEN** user enters filter with field `discovery_sources` and value `armis`
- **THEN** the builder generates query token `discovery_sources:(armis)`

#### Scenario: Multiple values for array field
- **GIVEN** `discovery_sources` is configured as an array field
- **WHEN** user enters filter with field `discovery_sources` and values `armis,sweep`
- **THEN** the builder generates query token `discovery_sources:(armis,sweep)`

#### Scenario: Single value for scalar field unchanged
- **GIVEN** `hostname` is NOT configured as an array field
- **WHEN** user enters filter with field `hostname` and value `server01`
- **THEN** the builder generates query token `hostname:server01` (no list syntax)

#### Scenario: Catalog defines array fields per entity
- **GIVEN** the SRQL Catalog entity configuration
- **WHEN** an entity has array-backed database columns
- **THEN** the Catalog includes an `array_fields` list identifying those fields

## MODIFIED Requirements

### Requirement: SRQL Catalog entity configuration
The SRQL Catalog entity configuration SHALL support an optional `array_fields` list that identifies fields backed by array columns in the database.

#### Scenario: Devices entity includes array_fields
- **GIVEN** the devices entity in the SRQL Catalog
- **WHEN** the Catalog is configured
- **THEN** the entity includes `array_fields: ["discovery_sources", "tags"]`
