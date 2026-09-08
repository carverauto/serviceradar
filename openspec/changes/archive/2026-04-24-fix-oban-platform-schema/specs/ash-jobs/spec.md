## ADDED Requirements

### Requirement: Oban Database Schema

The system SHALL ensure Oban job tables exist in the `platform` PostgreSQL schema before starting Oban processes.

The migration system MUST handle these scenarios:
1. Fresh install with no existing Oban tables - create tables in `platform` schema
2. Existing install with tables in `public` schema only - migrate tables to `platform` schema
3. Existing install with tables in `platform` schema - verify completeness and no-op
4. Existing install with tables in both schemas - use `platform` schema, log warning

The system MUST NOT start Oban processes until schema validation passes.

#### Scenario: Fresh docker-compose install

- **GIVEN** a fresh database with no Oban tables in any schema
- **WHEN** the application starts with `SERVICERADAR_CORE_RUN_MIGRATIONS=true`
- **THEN** migrations create `platform.oban_jobs` and `platform.oban_peers` tables
- **AND** Oban starts successfully with no errors

#### Scenario: Upgrade from public schema install

- **GIVEN** an existing database with Oban tables in `public` schema only
- **WHEN** the application starts and runs migrations
- **THEN** the migration copies table structure to `platform` schema
- **AND** the system logs a warning about the schema migration
- **AND** Oban starts successfully using `platform` schema tables

#### Scenario: Startup with missing Oban tables

- **GIVEN** a database where Oban tables do not exist in the expected `platform` schema
- **AND** migrations have already run (migration tracking shows complete)
- **WHEN** the application attempts to start Oban
- **THEN** startup validation detects the missing tables
- **AND** the system logs an error with remediation steps
- **AND** the application fails gracefully instead of crashing with `undefined_table`

### Requirement: Oban Schema Validation at Startup

The system SHALL validate Oban table presence before starting Oban processes.

Validation MUST check for:
- `platform.oban_jobs` table exists
- `platform.oban_peers` table exists
- Required indexes exist on `oban_jobs`

#### Scenario: Validation passes

- **GIVEN** all required Oban tables exist in `platform` schema
- **WHEN** startup validation runs
- **THEN** validation returns success
- **AND** Oban processes start normally

#### Scenario: Validation fails with clear error

- **GIVEN** `platform.oban_jobs` table does not exist
- **WHEN** startup validation runs
- **THEN** validation returns failure with specific error message
- **AND** error message includes: missing table name, expected schema, remediation command
- **AND** application logs error at `:error` level
