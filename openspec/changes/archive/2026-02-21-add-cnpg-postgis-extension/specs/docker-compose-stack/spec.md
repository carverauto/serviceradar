## ADDED Requirements
### Requirement: Docker Compose CNPG bootstrap enables PostGIS
The Docker Compose stack SHALL initialize PostGIS automatically during CNPG bootstrap so geospatial SQL is available after a clean startup.

#### Scenario: Clean boot enables PostGIS
- **GIVEN** a clean environment with `docker compose down -v`
- **WHEN** `docker compose up -d` completes and CNPG is healthy
- **THEN** running `CREATE EXTENSION IF NOT EXISTS postgis;` in the application database succeeds
- **AND** `SELECT postgis_full_version();` returns a non-empty version string.

#### Scenario: Restart preserves PostGIS availability
- **GIVEN** a stack that has already completed bootstrap with persisted volumes
- **WHEN** the stack is restarted
- **THEN** PostGIS remains available without rerunning manual SQL steps.
