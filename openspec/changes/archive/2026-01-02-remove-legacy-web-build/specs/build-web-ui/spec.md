## ADDED Requirements
### Requirement: Default builds exclude legacy Next.js UI outputs
The build system SHALL exclude legacy `serviceradar-web` Next.js outputs from default Bazel wildcard builds and push workflows, while keeping `web-ng` as the only default UI artifact.

#### Scenario: Bazel wildcard build skips legacy UI
- **GIVEN** a clean checkout
- **WHEN** `bazel build //... --config=remote` runs
- **THEN** legacy `serviceradar-web` targets are not built and `web-ng` artifacts remain available via their targets.

#### Scenario: push_all omits legacy UI tags
- **GIVEN** the release push workflow
- **WHEN** `bazel run //docker/images:push_all` completes
- **THEN** it does not publish `serviceradar-web` image tags and only publishes `serviceradar-web-ng` for the UI.

### Requirement: Default deployments serve web-ng only
Default deployment manifests SHALL deploy the Phoenix `web-ng` UI and SHALL NOT reference the legacy `serviceradar-web` service.

#### Scenario: Docker Compose uses web-ng
- **GIVEN** the default `docker-compose.yml`
- **WHEN** `docker compose up -d` is executed
- **THEN** the UI service is `web-ng` and no `serviceradar-web` container is created.

#### Scenario: Helm/K8s defaults use web-ng
- **GIVEN** the default Helm chart and demo K8s manifests
- **WHEN** they are rendered/applied
- **THEN** UI resources reference `serviceradar-web-ng` and do not deploy `serviceradar-web`.
