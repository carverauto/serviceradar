# ash-cluster Specification

## Purpose
TBD - created by archiving change integrate-ash-framework. Update Purpose after archive.
## Requirements
### Requirement: libcluster Integration
The system SHALL use libcluster for ERTS cluster formation and node discovery.

#### Scenario: Cluster formation on startup
- **WHEN** a ServiceRadar node starts
- **THEN** libcluster SHALL attempt to join the configured cluster
- **AND** the node SHALL be visible in the ERTS cluster
- **AND** Horde registries SHALL begin synchronization

#### Scenario: Node disconnect handling
- **GIVEN** a node is connected to the cluster
- **WHEN** the node becomes unreachable
- **THEN** libcluster SHALL detect the disconnect
- **AND** the node SHALL be removed from the cluster view
- **AND** Horde SHALL redistribute processes as needed

### Requirement: Kubernetes Cluster Strategy
The system SHALL support Cluster.Strategy.Kubernetes for production deployments.

#### Scenario: Kubernetes DNS-based discovery
- **GIVEN** nodes deployed in a Kubernetes cluster
- **WHEN** a new pod starts with the serviceradar label
- **THEN** libcluster SHALL discover the pod via headless service DNS
- **AND** the new node SHALL join the cluster within polling_interval
- **AND** the new node SHALL be available for job routing

#### Scenario: Kubernetes pod termination
- **GIVEN** a gateway pod in the Kubernetes cluster
- **WHEN** the pod is terminated (graceful or forced)
- **THEN** Kubernetes strategy SHALL detect pod removal
- **AND** in-flight jobs SHALL be reassigned to available gateways

### Requirement: EPMD Cluster Strategy
The system SHALL support Cluster.Strategy.Epmd for development and bare metal deployments.

#### Scenario: Static host configuration
- **GIVEN** a static list of node hostnames in configuration
- **WHEN** the application starts
- **THEN** the node SHALL attempt to connect to all configured hosts
- **AND** connected hosts SHALL form an ERTS cluster

#### Scenario: DNS-based bare metal discovery
- **GIVEN** DNS records pointing to cluster nodes
- **WHEN** using DNSPoll strategy
- **THEN** nodes SHALL be discovered via DNS polling
- **AND** new nodes added to DNS SHALL join the cluster

### Requirement: Dynamic Cluster Membership
The system SHALL support adding and removing nodes without application restart.

#### Scenario: Runtime node addition
- **GIVEN** a running cluster with N nodes
- **WHEN** a new node is added to the topology configuration
- **THEN** the ClusterSupervisor SHALL update the topology
- **AND** the new node SHALL join without restarting existing nodes

#### Scenario: Runtime node removal
- **GIVEN** a node that needs to be decommissioned
- **WHEN** the node is gracefully removed from topology
- **THEN** jobs SHALL drain from the node
- **AND** registrations SHALL be transferred to remaining nodes
- **AND** the node SHALL leave the cluster cleanly

### Requirement: mTLS for ERTS Distribution
The system SHALL use mutual TLS for all inter-node communication.

#### Scenario: TLS certificate validation
- **WHEN** a node attempts to join the cluster
- **THEN** the node SHALL present a valid certificate
- **AND** the certificate SHALL be signed by the trusted CA
- **AND** connection SHALL fail if certificate is invalid

#### Scenario: Encrypted inter-node communication
- **GIVEN** two nodes in the cluster
- **WHEN** they communicate via ERTS distribution
- **THEN** all traffic SHALL be encrypted with TLS
- **AND** no plaintext data SHALL traverse the network

#### Scenario: Certificate rotation
- **GIVEN** node certificates approaching expiration
- **WHEN** new certificates are deployed
- **THEN** nodes SHALL use new certificates without restart
- **AND** existing connections SHALL gracefully transition

### Requirement: Cluster Health Monitoring
The system SHALL monitor cluster health and connectivity.

#### Scenario: Node connectivity check
- **WHEN** /health/cluster is requested
- **THEN** the response SHALL include:
  - Total nodes in cluster
  - Connected node names
  - Last seen timestamps per node
  - Cluster partition status

#### Scenario: Cluster partition detection
- **GIVEN** a network partition occurs
- **WHEN** the cluster splits into multiple groups
- **THEN** the system SHALL detect the partition
- **AND** log a warning with affected nodes
- **AND** emit a cluster:partition telemetry event

### Requirement: Cluster Strategy Configuration
The system SHALL support runtime configuration of cluster strategy.

#### Scenario: Strategy selection via environment
- **GIVEN** CLUSTER_STRATEGY environment variable is set
- **WHEN** the application starts
- **THEN** the specified strategy SHALL be used
- **AND** fallback to EPMD if variable is not set

#### Scenario: Strategy-specific configuration
- **WHEN** using Kubernetes strategy
- **THEN** NAMESPACE environment variable SHALL determine namespace
- **AND** kubernetes_selector SHALL filter relevant pods
- **AND** kubernetes_node_basename SHALL be configurable

