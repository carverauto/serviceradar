# deployment-versioning Specification

## Purpose
TBD - created by archiving change update-dev-image-tags. Update Purpose after archive.
## Requirements
### Requirement: Dev image tag defaults
The system SHALL default Helm and Docker Compose deployments to `latest` image tags when no explicit tag override is provided.

#### Scenario: Helm install with no tag override
- **WHEN** a Helm install is run with no `global.imageTag` override
- **THEN** ServiceRadar workloads use `latest` tags

#### Scenario: Docker Compose with no APP_TAG
- **WHEN** Docker Compose is started without `APP_TAG`
- **THEN** ServiceRadar services use `latest` tags

### Requirement: Explicit tag pinning
The system SHALL allow operators to pin all ServiceRadar images to a specific tag via a single override.

#### Scenario: Helm tag override
- **WHEN** `global.imageTag` is set to a specific tag
- **THEN** ServiceRadar workloads use that tag

#### Scenario: Compose tag override
- **WHEN** `APP_TAG` is set to a specific tag
- **THEN** Docker Compose uses that tag for ServiceRadar images

### Requirement: Latest tag publishing
The build/push workflow SHALL publish `latest` tags for ServiceRadar images in dev/test runs.

#### Scenario: Push latest tags
- **WHEN** `make push_all` is executed in a dev/test workflow
- **THEN** the registry has updated `latest` tags for ServiceRadar images

