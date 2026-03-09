## MODIFIED Requirements

### Requirement: ServiceRadar CNPG deployments use the custom image

The default ServiceRadar CNPG deployment paths (demo Kubernetes manifests and Helm chart) MUST consume the custom Postgres image and initialize the required extensions in the application database without depending on SPIRE-specific database components. Optional SPIFFE/SPIRE-related Postgres resources MAY still be rendered when that mode is explicitly enabled.

#### Scenario: Default demo deployment uses the custom image without SPIRE dependency

- **GIVEN** the default `k8s/demo` deployment path
- **WHEN** the `cnpg` pods become Ready
- **THEN** their container image is the published custom tag
- **AND** `SELECT extname FROM pg_extension` in the initialized application database lists the required extensions
- **AND** the deployment does not depend on SPIRE-specific CNPG resources being installed

#### Scenario: Default Helm deployment uses the custom image without SPIRE flags

- **GIVEN** `helm template serviceradar ./helm/serviceradar` with default values
- **WHEN** the rendered CNPG manifest is inspected
- **THEN** it references the published custom image
- **AND** extension bootstrap SQL includes the required application database extensions
- **AND** the render does not require `spire.enabled=true` or `spire.postgres.enabled=true`

#### Scenario: Optional SPIFFE mode may add SPIRE database resources

- **GIVEN** a Helm render with SPIFFE/SPIRE and SPIRE Postgres explicitly enabled
- **WHEN** the rendered manifests are inspected
- **THEN** the optional SPIRE database resources are present alongside the application CNPG resources
- **AND** the default application database path remains intact

### Requirement: Clean rebuild path for default ServiceRadar CNPG deployment

Operators MUST have a documented, testable rebuild path that deletes and recreates the default ServiceRadar CNPG deployment, re-applies the default manifests or Helm release, and validates the system from a clean slate without requiring SPIRE-specific prerequisites.

#### Scenario: Recreate default deployment without SPIRE prerequisites

- **GIVEN** a ServiceRadar Kubernetes deployment using the default Secret-backed mTLS path
- **WHEN** the documented rebuild steps are followed from a clean namespace
- **THEN** CNPG, application services, and internal mTLS bootstrap complete successfully
- **AND** the operator does not need to install SPIRE CRDs or SPIRE workloads to restore the deployment
