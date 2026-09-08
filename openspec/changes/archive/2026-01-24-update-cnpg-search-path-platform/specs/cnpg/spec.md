## ADDED Requirements
### Requirement: CNPG search_path prefers platform schema
CNPG bootstrap configuration SHALL set the database search_path to `platform, ag_catalog` so new tables are created under the platform schema rather than public.

#### Scenario: Fresh bootstrap uses platform-first search_path
- **GIVEN** a fresh CNPG cluster bootstrapped via Helm or Docker Compose
- **WHEN** a client connects as the `serviceradar` role and queries `SHOW search_path`
- **THEN** the result starts with `platform`
- **AND** tables created by migrations are placed under the `platform` schema
