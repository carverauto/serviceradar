# docker-compose-stack Specification

## Purpose
TBD - created by archiving change fix-docker-compose-stack. Update Purpose after archive.
## Requirements
### Requirement: Docker Compose stack boots without manual intervention
The Docker Compose stack SHALL reach a healthy state after a clean `docker compose up -d` without manual migrations or ad-hoc fixes, while generating unique per-install trust-boundary secrets instead of relying on shared static defaults.

#### Scenario: Clean boot
- **WHEN** a user removes compose volumes and runs `docker compose up -d`
- **THEN** all required services become healthy within the expected startup window
- **AND** no manual schema or credential steps are required

#### Scenario: First boot generates unique runtime trust secrets
- **GIVEN** a clean Docker Compose environment with no secret volumes
- **WHEN** the stack performs bootstrap
- **THEN** it generates unique runtime secret material for Erlang distribution, Phoenix signing, and plugin download signing
- **AND** those values are persisted for reuse on restart
- **AND** the stack does not depend on shipped static defaults for those trust boundaries

### Requirement: Migrations are idempotent and serialized
The stack SHALL apply database migrations in a way that tolerates restarts and avoids duplicate table/index errors.

#### Scenario: Repeated startup
- **WHEN** the stack is restarted multiple times
- **THEN** migration runners do not fail with duplicate schema errors

### Requirement: Oban schema is provisioned automatically
The stack SHALL create Oban tables as part of startup migrations so job processing can run immediately.

#### Scenario: Web NG starts with Oban enabled
- **WHEN** web-ng starts with `SERVICERADAR_WEB_NG_OBAN_ENABLED=true`
- **THEN** Oban boots without missing table errors (e.g., `oban_peers`)

### Requirement: NATS JWT credentials are consistently used
All services that connect to NATS in Docker Compose SHALL use JWT credentials and succeed authentication, and the stack SHALL NOT publish unauthenticated NATS monitoring externally by default.

#### Scenario: NATS authentication
- **WHEN** services establish NATS connections
- **THEN** NATS logs show successful JWT authentication
- **AND** no services attempt anonymous or non-JWT connections

#### Scenario: Monitoring stays internal by default
- **WHEN** the main Docker Compose stack is rendered with default settings
- **THEN** the NATS monitoring endpoint is not published to non-loopback host interfaces by default
- **AND** any external monitoring exposure requires explicit operator opt-in

### Requirement: Zen stream initialization succeeds
Zen SHALL be able to update the `events` stream and seed initial rules without JetStream subject overlap errors.

#### Scenario: Zen startup
- **WHEN** the zen service starts with the compose config
- **THEN** it can add the required subjects to the `events` stream
- **AND** initial rule seeding completes without JetStream or auth failures

### Requirement: Default Docker Compose stack excludes dev-only services
The default Docker Compose stack SHALL not include dev-only services such as faker.

#### Scenario: Default stack configuration
- **WHEN** a user runs `docker compose up -d` with the default compose file
- **THEN** the faker service is not defined or started
- **AND** the stack remains production-oriented

### Requirement: Dev compose stack provides opt-in faker
The development Docker Compose configuration SHALL provide faker only when explicitly enabled via a dev compose file or overlay.

#### Scenario: Dev stack opt-in
- **WHEN** a user enables the dev compose configuration
- **THEN** the faker service is included and starts successfully
- **AND** the base compose stack remains unchanged

### Requirement: Docker Compose persists database credentials
The Docker Compose stack MUST generate random credentials for the `postgres` superuser and application roles on first boot, store them in a dedicated volume, and reuse them on restart.

#### Scenario: First boot generates credentials
- **GIVEN** a clean Docker Compose environment with no credential volume
- **WHEN** the stack is started
- **THEN** credential files are created in the volume with random values
- **AND** CNPG uses those values for superuser and app roles

#### Scenario: Restart reuses stored credentials
- **GIVEN** credential files exist in the volume
- **WHEN** the stack is restarted
- **THEN** CNPG and application services read the existing values without regenerating them

### Requirement: Existing CNPG data requires explicit credentials
When the CNPG data volume already exists, the Docker Compose bootstrap MUST fail fast unless the credential files are present or explicit passwords are provided for seeding.

#### Scenario: Existing DB without credentials
- **GIVEN** the CNPG data volume already exists
- **AND** the credentials volume does not contain password files
- **WHEN** the bootstrap job starts without `CNPG_PASSWORD`, `CNPG_SUPERUSER_PASSWORD`, or `CNPG_SPIRE_PASSWORD`
- **THEN** the bootstrap job exits with an error before CNPG-dependent services start

### Requirement: Docker Compose CNPG binding is loopback by default
The Docker Compose CNPG service MUST bind its Postgres port to loopback by default, requiring an explicit override to expose it publicly.

#### Scenario: Default binding is loopback
- **GIVEN** no `CNPG_PUBLIC_BIND` override in the environment
- **WHEN** the Docker Compose stack is rendered
- **THEN** the CNPG port binding is `127.0.0.1:<port>:5432`

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

### Requirement: Docker Compose seeds NetFlow Zen rules when enabled
The Docker Compose stack SHALL run a NetFlow rule seeding step when NetFlow ingestion is enabled so Zen can process
NetFlow records immediately after startup, retrying on transient KV failures.

#### Scenario: NetFlow-enabled compose boot
- **GIVEN** the compose stack enables the NetFlow collector
- **WHEN** the stack starts
- **THEN** a `zen-put-rule` step SHALL seed the NetFlow rule bundle into KV
- **AND** transient KV failures SHALL trigger retries before reporting failure
- **AND** the NetFlow rule seeding step SHALL complete before NetFlow traffic is processed

### Requirement: Docker Compose SPIRE bootstrap artifacts are integrity pinned
The Docker Compose SPIRE bootstrap path MUST NOT download and execute unsigned binaries from the network at runtime.

#### Scenario: SPIRE bootstrap uses vetted artifacts
- **WHEN** the compose SPIRE bootstrap initializes the SPIRE server CLI or agent binary
- **THEN** it uses binaries that are already present in the image or a vetted local artifact path
- **OR** it verifies a pinned checksum or signature before extracting and executing a downloaded artifact

#### Scenario: Unverified runtime download is rejected
- **WHEN** the compose SPIRE bootstrap cannot establish the configured integrity material for a downloaded artifact
- **THEN** bootstrap fails closed
- **AND** it does not execute the downloaded binary

### Requirement: Docker Compose agent can reach the gateway
The Docker Compose stack SHALL configure the agent and agent-gateway services so that the agent can resolve and connect to the gateway gRPC endpoint without manual edits.

#### Scenario: Agent enrollment on clean boot
- **GIVEN** a user removes compose volumes and runs `docker compose up -d`
- **WHEN** the agent container starts
- **THEN** the agent connects to the agent-gateway gRPC endpoint using the compose DNS alias
- **AND** the gateway logs show a successful agent enrollment

### Requirement: Docker Compose CNPG major-version mismatch fails fast
The Docker Compose stack MUST detect when the mounted CNPG data volume was
initialized by a different Postgres major version than the configured CNPG
image and MUST stop before starting Postgres with an actionable migration
message.

#### Scenario: PG16 data volume on PG18 image
- **GIVEN** a Docker Compose `cnpg-data` volume whose `PG_VERSION` file reports PostgreSQL 16
- **AND** the Compose stack targets a PostgreSQL 18 CNPG image
- **WHEN** the `cnpg` service starts
- **THEN** the stack exits before Postgres boots on that data directory
- **AND** the error message explains that Docker Compose does not perform major upgrades automatically
- **AND** the error message points the operator to the supported migration workflow

### Requirement: Docker Compose provides a controlled CNPG PG16-to-PG18 migration workflow
The Docker Compose stack MUST provide a supported workflow for migrating an
existing PG16 CNPG local volume to a PG18-compatible local volume without
requiring manual schema repair after the upgrade.

#### Scenario: Existing local CNPG volume is migrated to PG18
- **GIVEN** a Docker Compose install with a persisted PG16 `cnpg-data` volume
- **WHEN** the operator starts the Docker Compose stack on the PG18 image
- **THEN** the workflow produces a PG18-compatible CNPG data volume
- **AND** ServiceRadar application data is preserved
- **AND** the Compose stack can start successfully on PG18 after the migration completes

#### Scenario: Existing local PG18 volume skips migration
- **GIVEN** a Docker Compose install with a persisted PG18 `cnpg-data` volume
- **WHEN** the operator starts the Docker Compose stack
- **THEN** the migration step exits successfully without rewriting the data volume
- **AND** normal Compose startup continues

### Requirement: Docker Compose migration preserves effective database credentials
The Docker Compose CNPG migration workflow MUST preserve the effective
superuser and application credential state needed by the upgraded
stack, including legacy installs that predate the dedicated credentials volume.

#### Scenario: Legacy install without persisted credentials migrates successfully
- **GIVEN** a Docker Compose install with a PG16 CNPG data volume and no persisted `cnpg-credentials` volume
- **AND** the install previously used the legacy Compose credential defaults
- **WHEN** the operator starts the Docker Compose stack on the PG18 image
- **THEN** the migrated stack starts with credentials that match the effective legacy install state
- **AND** core/web-ng/CNPG connections succeed without requiring manual password resets

