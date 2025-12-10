## ADDED Requirements

### Requirement: CNPG image uses stable TimescaleDB release
The CNPG Postgres image MUST be built with stable TimescaleDB releases, not development versions, to ensure retention policy creation and other TimescaleDB features work reliably during fresh database initialization.

#### Scenario: TimescaleDB version matches stable release
- **GIVEN** a fresh cnpg container started from `ghcr.io/carverauto/serviceradar-cnpg:<version>`
- **WHEN** `SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';` runs
- **THEN** the version returned is a stable release (e.g., `2.24.0`) without `-dev` suffix.

#### Scenario: Retention policies created without crashes
- **GIVEN** a fresh CNPG database with TimescaleDB extension enabled
- **WHEN** serviceradar-core runs migrations that call `add_retention_policy()` on hypertables
- **THEN** all retention policies are created successfully without postgres crashes or assertion failures.

#### Scenario: Fresh docker-compose deployment succeeds
- **GIVEN** a clean environment with `docker compose down -v` removing all volumes
- **WHEN** `docker compose up -d` starts the stack
- **THEN** cnpg becomes healthy, core completes all migrations, and all services reach healthy state.

### Requirement: CNPG build uses native TimescaleDB version
The CNPG image build process MUST NOT override TimescaleDB's native `version.config` file, ensuring the compiled extension version matches the source code version.

#### Scenario: No version.config override in build
- **GIVEN** the `timescaledb_extension_layer` genrule in `docker/images/BUILD.bazel`
- **WHEN** the build runs
- **THEN** the TimescaleDB source's original `version.config` is preserved without modification.

#### Scenario: Extension version matches source
- **GIVEN** MODULE.bazel specifies `timescaledb-2.24.0` as the source archive
- **WHEN** the cnpg image is built and deployed
- **THEN** `SELECT extversion FROM pg_extension WHERE extname = 'timescaledb';` returns `2.24.0`.
