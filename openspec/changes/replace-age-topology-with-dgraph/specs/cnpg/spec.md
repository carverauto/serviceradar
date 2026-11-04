## ADDED Requirements

### Requirement: Apache AGE graph storage is retired by a forward migration
A forward-only core migration SHALL remove the Apache AGE graph storage once Dgraph is the only topology graph: the `public.age_device_neighborhood` function, the `platform.runtime_topology_links` projection table, every graph registered in `ag_catalog.ag_graph`, graph schemas made only of AGE-typed label tables that AGE has no record of, and then the `age` extension without `CASCADE`. Before dropping any graph it SHALL verify through `pg_depend` that no object outside the graph schemas depends on them, and it SHALL refuse, naming the dependents, otherwise. A database without the `age` extension SHALL treat the AGE steps as a no-op, and a second run SHALL change nothing.

#### Scenario: Upgraded database with registered graphs
- **GIVEN** a database whose `ag_catalog.ag_graph` registers `platform_graph` and legacy graphs holding label tables
- **WHEN** the retirement migration runs as the CNPG superuser
- **THEN** each registered graph is dropped with `ag_catalog.drop_graph`
- **AND** the `age` extension and the `ag_catalog` schema no longer exist
- **AND** relational topology evidence tables keep their rows

#### Scenario: Database built from the schema baseline
- **GIVEN** a database built from the schema baseline, whose graph schemas have no `ag_catalog.ag_graph` rows
- **WHEN** the retirement migration runs
- **THEN** those schemas are removed with explicit, non-cascading `DROP TABLE`, `DROP SEQUENCE` and `DROP SCHEMA` statements
- **AND** the `age` extension is dropped

#### Scenario: Something outside a graph schema depends on it
- **GIVEN** a view in `platform` that selects from a label table
- **WHEN** the retirement migration runs
- **THEN** it raises an error naming the view and drops nothing

#### Scenario: Role that does not own the extension
- **GIVEN** a migrating role that is neither a superuser nor the owner of the `age` extension
- **WHEN** the retirement migration runs
- **THEN** the graphs are removed and the extension is left installed with a warning

## MODIFIED Requirements

### Requirement: CNPG search_path prefers platform schema
CNPG bootstrap configuration SHALL set the database search_path to `platform` (with `public` as the application default) so new tables are created under the platform schema rather than public. The search_path SHALL NOT include `ag_catalog`.

#### Scenario: Fresh bootstrap uses platform-first search_path
- **GIVEN** a fresh CNPG cluster bootstrapped via Helm or Docker Compose
- **WHEN** a client connects as the `serviceradar` role and queries `SHOW search_path`
- **THEN** the result starts with `platform`
- **AND** tables created by migrations are placed under the `platform` schema

### Requirement: CNPG upgrade workflows preserve application role access
Controlled CNPG major-upgrade workflows MUST preserve the application role
access model that ServiceRadar relies on after the upgrade completes.

#### Scenario: Application roles remain usable after Compose migration
- **GIVEN** a supported Compose PG16-to-PG18 migration has completed
- **WHEN** ServiceRadar services connect to the migrated PG18 CNPG cluster
- **THEN** the configured superuser and `serviceradar` roles can authenticate as expected
- **AND** the application database retains the required `platform` search_path behavior
