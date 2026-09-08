## MODIFIED Requirements

### Requirement: Default builds exclude legacy Next.js UI outputs
The build system SHALL only build `serviceradar-web-ng` (Phoenix) UI artifacts. The legacy `serviceradar-web` (Next.js) source code and all associated build targets have been completely removed from the codebase.

#### Scenario: Bazel wildcard build produces web-ng only
- **GIVEN** a clean checkout
- **WHEN** `bazel build //... --config=remote` runs
- **THEN** `web-ng` artifacts are built
- **AND** no legacy `web/` directory or targets exist in the codebase.

#### Scenario: push_all publishes web-ng UI only
- **GIVEN** the release push workflow
- **WHEN** `bazel run //docker/images:push_all` completes
- **THEN** it publishes `serviceradar-web-ng` for the UI
- **AND** no `serviceradar-web` image exists in push targets.

### Requirement: Default deployments serve web-ng only
Default deployment manifests SHALL deploy the Phoenix `web-ng` UI. The legacy `serviceradar-web` service, Docker images, packaging, and CI workflows have been completely removed.

#### Scenario: Docker Compose uses web-ng
- **GIVEN** the default `docker-compose.yml`
- **WHEN** `docker compose up -d` is executed
- **THEN** the UI service is `web-ng`
- **AND** no legacy `Dockerfile.web` or `entrypoint-web.sh` exists.

#### Scenario: Helm/K8s defaults use web-ng
- **GIVEN** the default Helm chart and demo K8s manifests
- **WHEN** they are rendered/applied
- **THEN** UI resources reference `serviceradar-web-ng`
- **AND** no legacy web packaging or RPM specs exist.
