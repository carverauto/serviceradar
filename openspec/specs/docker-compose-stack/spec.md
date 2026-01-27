# docker-compose-stack Specification

## Purpose
TBD - created by archiving change fix-docker-compose-stack. Update Purpose after archive.
## Requirements
### Requirement: Docker Compose stack boots without manual intervention
The Docker Compose stack SHALL reach a healthy state after a clean `docker compose up -d` without manual migrations or ad-hoc fixes.

#### Scenario: Clean boot
- **WHEN** a user removes compose volumes and runs `docker compose up -d`
- **THEN** all required services become healthy within the expected startup window
- **AND** no manual schema or credential steps are required

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
All services that connect to NATS in Docker Compose SHALL use JWT credentials and succeed authentication.

#### Scenario: NATS authentication
- **WHEN** services establish NATS connections
- **THEN** NATS logs show successful JWT authentication
- **AND** no services attempt anonymous or non-JWT connections

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

