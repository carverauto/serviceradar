## ADDED Requirements

### Requirement: Dgraph is the platform graph store
The system SHALL use Dgraph as the graph database for topology projections and subsequent graph workloads, deployed as a ServiceRadar-managed cluster rather than as a process inside CNPG.

#### Scenario: Topology does not share Postgres with the graph store
- **WHEN** topology edges are persisted after cutover
- **THEN** they are written to Dgraph
- **AND** they are not written to Apache AGE as the primary store

### Requirement: Product Helm installs Dgraph by default
The `helm/serviceradar` chart SHALL install and manage Dgraph so a user can `helm upgrade --install` without a prior Dgraph cluster.

#### Scenario: Default install starts Dgraph
- **WHEN** `helm template` is rendered with default values
- **THEN** the manifest includes Dgraph Zero and Alpha
- **AND** it includes a generated ACL Secret (not an inlined password)
- **AND** it includes a schema-migration Job that runs after Dgraph is Ready

#### Scenario: Upgrade is black-box
- **WHEN** an existing release is upgraded to a chart that includes Dgraph
- **THEN** Dgraph is created if absent
- **AND** ACL material is reused if already present
- **AND** the schema Job is idempotent
- **AND** the operator is not required to run a separate Dgraph installer

#### Scenario: External Dgraph is opt-out
- **GIVEN** `dgraph.enabled=false` and an external `dgraph://` endpoint
- **WHEN** the chart is rendered
- **THEN** Zero and Alpha are omitted
- **AND** application pods still receive the external connection string
- **AND** this path is not the documented default install

### Requirement: Managed cluster profiles
The chart SHALL ship a single-node profile and an HA profile that match the scaling rules already proven in `k8s/dgraph`.

#### Scenario: Single-node default for small installs
- **WHEN** the chart uses the single-node profile
- **THEN** it runs 1 Zero and 1 Alpha with `shardReplicaCount=1`
- **AND** images are the Harbor-mirrored Dgraph tag the chart pins

#### Scenario: HA profile for production
- **WHEN** the chart uses the HA profile
- **THEN** it runs 3 Zero and 3 Alpha with `shardReplicaCount=3`
- **AND** ACL and TLS remain enabled

### Requirement: Dedicated Dgraph namespace
The system SHALL store ServiceRadar topology in a dedicated Dgraph namespace under ACL isolation on the cluster the chart manages.

#### Scenario: Namespace isolation
- **GIVEN** ACL is enabled on the cluster
- **WHEN** ServiceRadar writes a topology node
- **THEN** the write is scoped to the configured namespace
- **AND** namespace 0 does not observe that node

### Requirement: Docker Compose Dgraph
The Docker Compose stack SHALL start a local Dgraph with ACL enabled so a clean `docker compose up -d` can project topology without a Kubernetes cluster.

#### Scenario: Compose boot includes Dgraph
- **WHEN** a user runs `docker compose up -d` with default settings
- **THEN** a Dgraph service becomes healthy
- **AND** the schema-migration one-shot applies the topology schema
- **AND** no manual Dgraph steps are required
