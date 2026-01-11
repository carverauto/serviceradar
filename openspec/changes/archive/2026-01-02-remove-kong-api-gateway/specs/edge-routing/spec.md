## ADDED Requirements
### Requirement: Edge routing without Kong
Default ServiceRadar deployments SHALL route user-facing HTTPS traffic directly to web-ng and SRQL services without inserting Kong.

#### Scenario: Docker Compose routes APIs without Kong
- **GIVEN** the default docker compose stack
- **WHEN** the stack is started
- **THEN** no Kong container is created and `/api` traffic routes directly to web-ng (including `/api/query` as configured).

#### Scenario: Helm/K8s defaults route APIs without Kong
- **GIVEN** default Helm charts and demo K8s manifests
- **WHEN** they are rendered/applied
- **THEN** there is no Kong deployment/service and UI/API routes point to web-ng and SRQL directly.

## REMOVED Requirements
### Requirement: Kong API gateway enforcement
**Reason**: Kong is no longer used in supported ServiceRadar deployments.
**Migration**: Move any required API routing/JWT enforcement to core/web-ng and the edge proxy.

#### Scenario: Legacy Kong routing removed
- **WHEN** deployments are rendered
- **THEN** Kong-specific services, config, and routes are not present by default.
