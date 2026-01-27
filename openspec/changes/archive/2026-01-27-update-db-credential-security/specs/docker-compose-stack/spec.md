## ADDED Requirements
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
