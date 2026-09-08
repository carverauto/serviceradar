## ADDED Requirements
### Requirement: Docker Compose uses a privileged migration role
The Docker Compose stack SHALL run ServiceRadar schema/extension bootstrap through Ash migrations using a privileged database role that is only used by the migration runner. Application services MUST continue to use the least-privilege app role.

#### Scenario: Clean boot with migration runner
- **GIVEN** a clean Docker Compose environment with no volumes
- **WHEN** a user runs `docker compose up -d`
- **THEN** the migration runner connects with the privileged role, applies migrations, and exits successfully
- **AND** core/web-ng/datasvc start using the app role without requiring elevated privileges

### Requirement: Docker Compose avoids ServiceRadar init SQL
The Docker Compose stack SHALL NOT rely on docker-entrypoint init scripts to create ServiceRadar roles, schema, or extensions.

#### Scenario: Init scripts removed
- **GIVEN** a clean Docker Compose environment
- **WHEN** CNPG initializes the database
- **THEN** ServiceRadar-specific schema changes are applied solely via Ash migrations
