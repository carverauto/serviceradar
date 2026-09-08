## ADDED Requirements
### Requirement: CNPG bootstrap credentials are generated and persisted
The Helm CNPG bootstrap MUST generate random passwords for the `postgres` superuser and `spire`/`serviceradar` roles when they are not explicitly provided, and MUST store them in Kubernetes secrets that persist across upgrades.

#### Scenario: New Helm install without provided passwords
- **GIVEN** a Helm install where CNPG passwords are not set in values
- **WHEN** the chart renders and installs CNPG resources
- **THEN** `cnpg-superuser`, `spire-db-credentials`, and `serviceradar-db-credentials` secrets contain non-empty, non-default passwords
- **AND** subsequent upgrades reuse the existing secret values without rotating them

#### Scenario: Existing secrets are preserved
- **GIVEN** `cnpg-superuser` or `spire-db-credentials` already exist in the namespace
- **WHEN** the chart is upgraded
- **THEN** the existing secret values are reused without being overwritten

### Requirement: CNPG cluster access is internal by default
The Helm CNPG deployment MUST avoid exposing CNPG services outside the cluster unless explicitly configured by the operator.

#### Scenario: Default Helm render is cluster-internal
- **GIVEN** a Helm install with default values
- **WHEN** the CNPG service manifests are rendered
- **THEN** services are ClusterIP-only (no NodePort or LoadBalancer exposure)
