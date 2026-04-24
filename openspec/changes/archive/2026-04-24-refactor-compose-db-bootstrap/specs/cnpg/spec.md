## MODIFIED Requirements
### Requirement: Fresh docker-compose deployment succeeds
The CNPG Docker Compose deployment MUST reach a healthy state on a clean `docker compose up -d`, and ServiceRadar schema/bootstrap MUST be applied via Ash migrations using a privileged migration role (not CNPG init scripts).

#### Scenario: Fresh docker-compose deployment succeeds
- **GIVEN** a clean environment with `docker compose down -v` removing all volumes
- **WHEN** `docker compose up -d` starts the stack
- **THEN** cnpg becomes healthy, the migration runner completes, and all services reach healthy state
- **AND** no ServiceRadar-specific SQL is executed in docker-entrypoint init scripts

## ADDED Requirements
### Requirement: Helm/Kubernetes bootstrap uses migration runner
Kubernetes/Helm deployments MUST run Ash migrations through a privileged migration runner (Job or init container) using a dedicated secret, MUST ensure the application database exists before migrations run, and MUST NOT rely on CNPG init SQL for ServiceRadar schema/bootstrap.

#### Scenario: Helm deployment bootstraps schema
- **GIVEN** a Helm install on a clean cluster
- **WHEN** the CNPG cluster becomes ready
- **THEN** a migration runner ensures the ServiceRadar database exists and executes Ash migrations using the privileged role
- **AND** core/web-ng start only after the migration runner completes
