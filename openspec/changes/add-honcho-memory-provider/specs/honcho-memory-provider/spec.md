## ADDED Requirements

### Requirement: Honcho memory provider runs in a dedicated `honcho` namespace on a dedicated CNPG-backed PostgreSQL cluster
The system SHALL support deploying Honcho as a self-hosted memory provider stack in Kubernetes inside a dedicated namespace named `honcho`, with durable PostgreSQL storage provided by a dedicated CloudNativePG cluster.

#### Scenario: Honcho stack is isolated into the `honcho` namespace
- **GIVEN** an operator deploys the Honcho memory provider stack in a ServiceRadar-managed Kubernetes environment
- **WHEN** the namespace and workload manifests are inspected
- **THEN** the Honcho API, dashboard, worker/background processor, HA Redis deployment, and dedicated Honcho CNPG cluster resources are created in the `honcho` namespace

#### Scenario: Honcho database uses a dedicated CNPG-managed PostgreSQL cluster
- **GIVEN** an operator deploys the Honcho memory provider stack in a ServiceRadar-managed Kubernetes environment
- **WHEN** the PostgreSQL dependency is rendered or applied
- **THEN** the deployment uses a dedicated CNPG `Cluster` for Honcho persistence rather than reusing an existing ServiceRadar database cluster
- **AND** Honcho application components connect to that dedicated CNPG-managed PostgreSQL endpoint for durable state

#### Scenario: Honcho uses the ServiceRadar CNPG custom image
- **GIVEN** the Honcho PostgreSQL dependency is provisioned by ServiceRadar manifests
- **WHEN** the CNPG manifest is inspected
- **THEN** `imageName` references `registry.carverauto.dev/serviceradar/serviceradar-cnpg:18.3.0-sr2-a78b3afd` or the corresponding pinned digest form already used by ServiceRadar CNPG manifests

### Requirement: Honcho self-hosting includes required supporting services
The self-hosted Honcho deployment SHALL include all supporting runtime services required for application startup and background processing, including an HA Redis deployment when Redis is required by the target Honcho version.

#### Scenario: Required runtime roles are modeled explicitly
- **GIVEN** the Honcho self-hosted stack is rendered for Kubernetes
- **WHEN** the operator inspects the manifests
- **THEN** the deployment includes manifests or documented wiring for the Honcho API/backend, dashboard/UI, and any required worker/background processor roles
- **AND** the deployment includes an HA Redis topology when the Honcho target version requires it for queues, cache, or background jobs

#### Scenario: Supporting services remain internal by default
- **GIVEN** the Honcho stack is deployed with default ServiceRadar values in the `honcho` namespace
- **WHEN** the rendered Services are inspected
- **THEN** CNPG and HA Redis are exposed only on internal cluster endpoints unless an operator explicitly enables another exposure pattern

### Requirement: Honcho API and dashboard can be exposed through a controlled private-network path without exposing CNPG or Redis
The deployment SHALL support a controlled Kubernetes exposure path for the Honcho API and dashboard so Hermes Agent and operators can reach Honcho when required, while keeping CNPG and HA Redis internal-only.

#### Scenario: Controlled exposure is limited to application services
- **GIVEN** an operator enables durable network access for Honcho
- **WHEN** the rendered manifests are inspected
- **THEN** only the Honcho API and/or dashboard services are exposed through a controlled ingress, Gateway API route, or another explicitly managed service pattern
- **AND** CNPG and HA Redis remain internal-only cluster services

#### Scenario: Durable access avoids broad public exposure by default
- **GIVEN** an operator enables non-cluster-local access for Honcho
- **WHEN** the chosen exposure pattern is reviewed
- **THEN** the preferred path uses a private/internal network entrypoint rather than assigning a broad public 80/443 endpoint by default

#### Scenario: Internal-only remains the default posture
- **GIVEN** an operator deploys the Honcho stack without opting into durable external or internal-network access
- **WHEN** the rendered manifests are inspected
- **THEN** no ingress or external LoadBalancer is created for Honcho application services by default
- **AND** temporary smoke-test access may still be performed through cluster-local methods such as port-forwarding until explicit exposure is configured

### Requirement: Honcho configuration is secret-backed and env-driven
The self-hosted Honcho deployment SHALL use Kubernetes-managed secret/config inputs for the upstream Honcho self-hosting configuration surface, and GitOps-managed secrets SHALL be delivered through SealedSecrets or an equivalent encrypted-at-rest GitOps secret mechanism.

#### Scenario: Database and HA Redis connectivity are configured without image rebuilds
- **GIVEN** an operator provides the required Honcho secrets/configuration through the chosen GitOps-compatible secret delivery mechanism
- **WHEN** the Honcho pods start
- **THEN** Honcho reads PostgreSQL and Redis connection settings from Kubernetes-managed environment configuration
- **AND** the deployment does not require manual in-container edits to connect to CNPG or HA Redis

#### Scenario: Upstream env var names are preserved
- **GIVEN** the target Honcho version documents exact environment variable names for self-hosting
- **WHEN** ServiceRadar configures the Honcho pods
- **THEN** the pod environment uses those documented upstream variable names for database, Redis, URL, and secret settings
- **AND** ServiceRadar does not introduce undocumented aliases that diverge from upstream behavior

### Requirement: Honcho startup waits for dependency readiness
The Honcho self-hosted deployment SHALL make database initialization and dependency readiness explicit so application components do not report healthy before their required services are available.

#### Scenario: Honcho initialization completes against CNPG before steady-state readiness
- **GIVEN** a fresh deployment with an empty Honcho PostgreSQL database
- **WHEN** the Honcho stack starts
- **THEN** the required initialization or migration flow completes successfully against the CNPG-backed database
- **AND** the API/dashboard pods do not report Ready until the required startup dependencies are satisfied

#### Scenario: Redis dependency failures are operator-visible
- **GIVEN** Honcho requires Redis for the target self-hosted version
- **WHEN** Redis is unavailable during startup
- **THEN** Honcho worker or application components fail in a diagnosable way
- **AND** the deployment exposes a clear readiness or startup failure signal instead of silently running in a degraded state

### Requirement: Operators can validate the self-hosted memory workflow end-to-end
The deployment SHALL include a documented verification path that proves the self-hosted Honcho memory provider is functional on top of CNPG.

#### Scenario: End-to-end memory-provider verification succeeds
- **GIVEN** the Honcho stack is deployed successfully
- **WHEN** an operator runs the documented verification steps
- **THEN** the verification confirms CNPG readiness, Redis readiness, Honcho process readiness, and a successful basic memory write/read workflow
