## MODIFIED Requirements

### Requirement: CNPG search_path prefers platform schema
CNPG bootstrap configuration SHALL set the database search_path to `platform, ag_catalog` so new tables are created under the platform schema rather than public. The search_path value SHALL NOT be quoted as a single identifier.

#### Scenario: Fresh bootstrap uses platform-first search_path
- **GIVEN** a fresh CNPG cluster bootstrapped via Helm or Docker Compose
- **WHEN** a client connects as the `serviceradar` role and queries `SHOW search_path`
- **THEN** the result starts with `platform` (without surrounding double quotes)
- **AND** tables created by migrations are placed under the `platform` schema
- **AND** tables can be accessed without schema prefix

#### Scenario: Search_path is not quoted as single identifier
- **GIVEN** the startup migrations set the search_path
- **WHEN** the SQL executes `ALTER ROLE ... SET search_path TO ...`
- **THEN** the search_path value SHALL NOT be wrapped in quotes
- **AND** the effective search_path SHALL be `platform, public, ag_catalog` (three separate schemas)
- **AND** the effective search_path SHALL NOT be `"platform, public, ag_catalog"` (single quoted identifier)

#### Scenario: Misconfigured search_path is auto-corrected
- **GIVEN** an existing deployment with search_path stored as `"platform, public, ag_catalog"` (quoted identifier)
- **WHEN** startup migrations run
- **THEN** the search_path SHALL be corrected to `platform, public, ag_catalog` (unquoted)
- **AND** subsequent queries SHALL find tables in the platform schema
