## ADDED Requirements

### Requirement: CNPG major upgrades use controlled migration workflows
ServiceRadar MUST NOT attempt unsupported direct reuse of Postgres data
directories across CNPG major versions. Supported upgrade paths MUST use a
controlled migration workflow appropriate to the deployment environment.

#### Scenario: Docker Compose blocks direct PG16-on-PG18 reuse
- **GIVEN** a Docker Compose deployment with a PG16 CNPG data directory
- **WHEN** the deployment is reconfigured to use the PG18 CNPG image
- **THEN** the system refuses to boot PG18 directly on the PG16 data directory
- **AND** it requires the operator to run the supported Compose migration workflow first

### Requirement: CNPG upgrade workflows preserve application role access
Controlled CNPG major-upgrade workflows MUST preserve the application role
access model that ServiceRadar relies on after the upgrade completes.

#### Scenario: Application roles remain usable after Compose migration
- **GIVEN** a supported Compose PG16-to-PG18 migration has completed
- **WHEN** ServiceRadar services connect to the migrated PG18 CNPG cluster
- **THEN** the configured superuser, `serviceradar`, and `spire` roles can authenticate as expected
- **AND** the application database retains the required `platform, ag_catalog` search_path behavior
