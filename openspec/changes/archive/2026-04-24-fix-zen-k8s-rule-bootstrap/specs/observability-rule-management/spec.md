## ADDED Requirements

### Requirement: Kubernetes Zen Rule Bootstrap
The system SHALL provide a Kubernetes-native mechanism to bootstrap initial Zen rules into the NATS KV store during Helm install and upgrade operations.

#### Scenario: Fresh Kubernetes install bootstraps rules
- **GIVEN** a fresh Kubernetes deployment via Helm
- **WHEN** the Helm chart is installed
- **THEN** the system SHALL run a bootstrap job to install default Zen rules
- **AND** the rules SHALL be stored in the NATS KV bucket with valid `DecisionContent` format (containing `nodes` and `edges`)
- **AND** the zen service SHALL be able to load these rules without errors

#### Scenario: Helm upgrade preserves existing valid rules
- **GIVEN** an existing Kubernetes deployment with valid Zen rules in KV
- **WHEN** the Helm chart is upgraded
- **THEN** the bootstrap job SHALL check if rules already exist with valid format
- **AND** existing valid rules SHALL NOT be overwritten
- **AND** the zen service SHALL continue to function normally

#### Scenario: Force reinstall option overwrites rules
- **GIVEN** an operator sets `zenRulesBootstrap.forceReinstall: true` in Helm values
- **WHEN** the Helm chart is upgraded
- **THEN** the bootstrap job SHALL reinstall all default rules
- **AND** existing rules SHALL be overwritten with the default definitions

#### Scenario: Bootstrap job handles missing dependencies gracefully
- **GIVEN** NATS or datasvc is not ready when the bootstrap job starts
- **WHEN** the job attempts to install rules
- **THEN** the job SHALL wait for dependencies to become available
- **AND** the job SHALL retry with exponential backoff
- **AND** the job SHALL fail after a configurable timeout if dependencies remain unavailable

## MODIFIED Requirements

### Requirement: Default Zen Rules and Reconciliation
The system SHALL seed baseline Zen rules into each tenant schema during onboarding (including the platform tenant),
SHALL reconcile stored Zen rules to datasvc KV from core-elx,
and SHALL provide Kubernetes-native bootstrap for fresh deployments.

#### Scenario: Tenant onboarding seeds Zen rules
- **WHEN** a tenant is created
- **THEN** the default Zen rules SHALL be inserted into the tenant schema
- **AND** each rule SHALL be eligible for KV sync without manual tooling

#### Scenario: Core-elx reconciles Zen rules
- **WHEN** core-elx starts or performs a scheduled reconciliation
- **THEN** active Zen rules in the database SHALL be re-published to KV

#### Scenario: Kubernetes bootstrap seeds initial rules before core-elx is available
- **WHEN** a fresh Kubernetes cluster is deployed
- **AND** core-elx has not yet created tenants or seeded rules
- **THEN** the Helm bootstrap job SHALL install minimal default rules directly to KV
- **AND** the zen service SHALL be able to process logs immediately
