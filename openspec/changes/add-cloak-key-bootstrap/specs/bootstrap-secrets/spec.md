## ADDED Requirements
### Requirement: CLOAK_KEY bootstrapping for deployments
The platform SHALL provision a base64-encoded 32-byte `CLOAK_KEY` for core-elx and web-ng across Docker Compose, Helm, and Kubernetes manifest installs. Deployments SHALL generate the key only when it is missing and SHALL fail fast when an existing key is empty or invalid. Valid operator-supplied keys MUST be preserved.

#### Scenario: Docker Compose boot without CLOAK_KEY
- **GIVEN** `docker compose up -d` is run without `CLOAK_KEY` set
- **WHEN** the cloak key generator runs
- **THEN** it writes `/etc/serviceradar/cloak/cloak.key` with a valid base64-encoded 32-byte key
- **AND** core-elx and web-ng read the key from `CLOAK_KEY_FILE` without failing to start

#### Scenario: Helm install with no cloakKey override
- **GIVEN** a Helm install with `secrets.autoGenerate=true` and no `secrets.cloakKey` override
- **WHEN** the secret generator job runs
- **THEN** `serviceradar-secrets` contains `cloak-key` with a valid base64-encoded 32-byte key
- **AND** core-elx and web-ng receive `CLOAK_KEY` from the secret

#### Scenario: Kubernetes manifest install with invalid key
- **GIVEN** a Kubernetes manifest install includes an empty or invalid `cloak-key`
- **WHEN** the secret generator job runs
- **THEN** the job fails fast and reports the invalid key

#### Scenario: Operator supplies an explicit CLOAK_KEY
- **GIVEN** an operator provides a valid base64-encoded 32-byte `cloak-key`
- **WHEN** the deployment is upgraded
- **THEN** the generator SHALL preserve the existing key
