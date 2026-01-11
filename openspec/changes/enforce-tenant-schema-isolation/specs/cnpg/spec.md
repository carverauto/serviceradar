## ADDED Requirements
### Requirement: Core-Elx Runs Ash Migrations on Startup
The core-elx service SHALL run Ash migrations for the public schema and all tenant schemas during startup, and SHALL fail startup if migrations cannot be applied.

#### Scenario: Startup migrations succeed
- **GIVEN** a core-elx instance with database access
- **WHEN** the service starts
- **THEN** Ash migrations SHALL be applied to the public schema
- **AND** tenant migrations SHALL be applied to every `tenant_<tenant_slug>` schema
- **AND** the service SHALL continue startup after migrations succeed

#### Scenario: Startup migrations fail fast
- **GIVEN** a core-elx instance with database access
- **WHEN** a migration fails
- **THEN** core-elx SHALL terminate startup
- **AND** application endpoints SHALL NOT be exposed until migrations succeed
