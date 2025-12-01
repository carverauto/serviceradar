## ADDED Requirements
### Requirement: AGE graph is bootstrapped in CNPG
The system SHALL create and maintain an Apache AGE graph named `serviceradar` in the CNPG database with the AGE extension enabled for all core/SRQL connections.

#### Scenario: Graph created at startup
- **WHEN** CNPG schema migrations run on a fresh cluster
- **THEN** `CREATE EXTENSION IF NOT EXISTS age; SELECT create_graph('serviceradar');` completes without error and the graph is available for subsequent queries.

#### Scenario: Idempotent graph readiness
- **WHEN** migrations or bootstrap jobs rerun on an existing cluster
- **THEN** the graph creation step is a no-op and AGE remains usable without dropping data.

### Requirement: Canonical nodes for devices, services, and collectors
The system SHALL model devices, services, and collectors as graph nodes keyed by their canonical IDs so they merge instead of duplicating when IPs or hostnames change.

#### Scenario: Device node merge by canonical ID
- **WHEN** a device update arrives for `canonical_device_id=sr:70c5563c-592f-458a-ab46-cb635fb01e3d` with a new IP
- **THEN** the AGE graph issues `MERGE (d:Device {id: 'sr:70c...'}) SET d.ip = '...'` and does not create a second Device node.

#### Scenario: Service node for internal component
- **WHEN** the sync service reports status with device ID `serviceradar:sync:sync` from agent `docker-agent`
- **THEN** the graph `MERGE`s a `Service {id: 'serviceradar:sync:sync', type: 'sync'}` node and links it to `Collector {id: 'serviceradar:agent:docker-agent'}` without creating a new Device node named `agent`.

#### Scenario: Collector identity from registry
- **WHEN** an agent or poller reconnects with a different pod IP
- **THEN** the graph retains a single `Collector` node keyed by `serviceradar:agent:<id>`/`serviceradar:poller:<id>` and updates the IP property instead of duplicating the collector.

### Requirement: Checker relationships attach to collectors, not devices
The system SHALL represent checker definitions and executions as relationships from collectors and services to their targets, and SHALL NOT create device nodes for collector host metadata.

#### Scenario: Collector health check does not create a device
- **WHEN** a checker result reports `checker_service=sync`, `checker_host_ip=172.18.0.5`, `collector_agent_id=docker-agent`
- **THEN** the graph records `(:Collector {id:'serviceradar:agent:docker-agent'})-[:RUNS_CHECKER {service:'sync'}]->(:Service {id:'serviceradar:sync:sync'})` and no Device node is created for `172.18.0.5`.

#### Scenario: Remote sysmon target becomes the device node
- **WHEN** a sysmon checker running on `docker-agent` polls target `192.168.1.218`
- **THEN** the graph links `Collector docker-agent` via `RUNS_CHECKER` to a `Service` node (sysmon) with a `TARGETS` edge to `Device {ip:'192.168.1.218'}`, and the collector IP is not promoted to a Device node.

### Requirement: Mapper-discovered interfaces are modeled as first-class nodes
The system SHALL store network interfaces discovered by mapper as Interface nodes linked to their devices and peer interfaces when topology is known.

#### Scenario: Interface attached to device
- **WHEN** mapper reports interface `eth0` on device `serviceradar:router:edge1` with MAC `aa:bb:cc:dd:ee:ff`
- **THEN** the graph `MERGE`s `(:Interface {id:'serviceradar:router:edge1/eth0', mac:'aa:bb:cc:dd:ee:ff'})-[:ON_DEVICE]->(:Device {id:'serviceradar:router:edge1'})`.

#### Scenario: Interface peer linkage
- **WHEN** mapper reports that `edge1/eth0` connects to `switch1/gi0/1`
- **THEN** the graph adds a `CONNECTS_TO` edge between the two Interface nodes to capture topology.

### Requirement: Capabilities and metrics availability are encoded in the graph
The system SHALL encode monitoring capabilities (e.g., SNMP, OTEL, sysmon) as graph relationships so the UI can render badges and filter results.

#### Scenario: SNMP metrics badge for router
- **WHEN** SNMP collection succeeds for target `192.168.1.1`
- **THEN** the graph links the target Device to a `Capability {type:'snmp'}` node (or edge property) so the inventory shows an SNMP metrics indicator for that device.

#### Scenario: Internal service health capability
- **WHEN** the sync service health check is ingested
- **THEN** the corresponding Service node is marked with `capabilities:['healthcheck']` (or a `PROVIDES_CAPABILITY` edge) so the UI can label it as a collector-owned health check rather than a standalone device.

### Requirement: Graph neighborhood query for inventory
The system SHALL expose an API/DAO to return a device’s immediate neighborhood (collector, services/checkers, interfaces, capabilities) for rendering in the inventory view.

#### Scenario: Inventory fetch distinguishes collector-owned services
- **WHEN** the UI requests the neighborhood for `serviceradar:sync:sync`
- **THEN** the API returns the Collector → Service relation with a flag indicating it is collector-owned, enabling the UI to label it instead of listing it as a device.

#### Scenario: Device neighborhood includes topology and collectors
- **WHEN** the UI requests the neighborhood for a router device
- **THEN** the API returns attached Interfaces, any CONNECTS_TO peers, and the Collectors/Services that target the device so operators can trace how the device is monitored.

### Requirement: Graph rebuild and drift detection
The system SHALL provide a job to rebuild the AGE graph from relational sources and emit drift metrics/alerts when graph ingestion fails or diverges.

#### Scenario: Rebuild restores graph after failure
- **WHEN** the rebuild job runs against an empty AGE graph
- **THEN** it rehydrates Devices, Services, Collectors, Interfaces, and their edges from canonical tables without reintroducing phantom collector devices.

#### Scenario: Drift alert on ingestion failures
- **WHEN** AGE writes fail for more than a configurable threshold (e.g., 5 minutes)
- **THEN** metrics/logs indicate graph drift and operators are alerted to rerun the rebuild job.

### Requirement: DIRE feeds the graph as the source of canonical device identity
The system SHALL emit DIRE-resolved device records into the AGE graph so the graph remains aligned with `unified_devices` and continues to apply collector-vs-target rules.

#### Scenario: DIRE update merges Device node
- **WHEN** DIRE resolves a device update for `canonical_device_id=sr:50487279-694c-44be-9ef3-40e1fe1eea57`
- **THEN** the graph `MERGE`s the Device node by that ID and updates properties (IP/hostname) without creating a new node, keeping parity with `unified_devices`.

#### Scenario: Collector host IP from checker is ignored
- **WHEN** DIRE receives a checker-sourced sighting whose host IP matches the collector `docker-agent`
- **THEN** no new Device node is created in AGE for that IP; the relationship is kept between the collector and the service/checker node only.

### Requirement: Mapper seeds and neighbors align to canonical devices
The system SHALL route mapper discoveries (seed targets, interfaces, neighbor devices) through DIRE and into the AGE graph so interfaces and neighbors attach to the correct canonical devices.

#### Scenario: Mapper seed promotes to device and interfaces
- **WHEN** a mapper job starts with seed `192.168.1.1`
- **THEN** DIRE promotes the seed into a canonical Device node; mapper-discovered interfaces on that seed attach to that Device in the graph.

#### Scenario: Neighbor discovery creates new device with interfaces
- **WHEN** mapper learns neighbor `192.168.10.1` via LLDP/CDP from the seed
- **THEN** the graph `MERGE`s a Device for the neighbor via DIRE canonical ID and attaches any discovered interfaces to that neighbor Device, with `CONNECTS_TO` edges between peer interfaces.

### Requirement: Inventory queries read from the graph, not only relational tables
The system SHALL serve device inventory and neighborhood queries from AGE (via DAO/SRQL) so UI/AI surfaces use graph relationships instead of flat `unified_devices` joins.

#### Scenario: Device Inventory uses graph neighborhood
- **WHEN** the UI requests the Device Inventory row for a device
- **THEN** the API fetches the device’s neighborhood from AGE (collector → services/checkers → capabilities) and renders badges/children without querying `unified_devices` directly.

#### Scenario: SRQL query sources topology from AGE
- **WHEN** SRQL is asked for a device’s connected collectors or services
- **THEN** it reads from the AGE graph to return relationships, ensuring poller/agent ownership and service health checks appear as children rather than duplicate devices.

### Requirement: Hierarchical UI views respect graph relationships
The system SHALL present hierarchical views backed by AGE: Device Inventory (device → services/collectors/child agents) and Network Discovery/Interfaces (device → interfaces) without listing interfaces as devices.

#### Scenario: Device inventory shows services under device
- **WHEN** viewing a device that has internal services (sync/mapper/zen) checked by an agent
- **THEN** those services render as children of that device/agent node with labels (e.g., collector service, healthcheck) instead of top-level devices.

#### Scenario: Interfaces page shows devices with discovered interfaces only
- **WHEN** opening the Network → Discovery → Interfaces page
- **THEN** only devices that have mapper-discovered interfaces are listed; expanding a device shows its interfaces and peer links, and interfaces are not shown as top-level devices elsewhere.

#### Scenario: Poller-to-agent hierarchy is visible
- **WHEN** a poller has registered agents
- **THEN** the inventory view shows the poller as a collector device with its agents as children, using graph relationships instead of duplicating device records.
