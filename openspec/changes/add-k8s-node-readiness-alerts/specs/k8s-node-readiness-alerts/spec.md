## ADDED Requirements

### Requirement: Kubernetes Node current-state inventory
The system SHALL publish a current-state inventory of Kubernetes Nodes from
the in-cluster `serviceradar-k8s-inventory` collector, including each Node's
name, cluster id, role (control-plane or worker), and `Ready` condition, on
JetStream subject `inventory.k8s.nodes` of stream `k8s_inventory`.

#### Scenario: Ready worker is inventoried
- **WHEN** the collector lists a Node whose `Ready` condition is True and that
  lacks control-plane role labels
- **THEN** the published snapshot SHALL include that Node with `ready` true
  and `role` worker

#### Scenario: NotReady control-plane node is inventoried
- **WHEN** the collector lists a Node whose `Ready` condition is False and that
  has `node-role.kubernetes.io/control-plane` or `node-role.kubernetes.io/master`
- **THEN** the published snapshot SHALL include that Node with `ready` false
  and `role` control-plane

#### Scenario: Host agents do not receive kube API credentials
- **WHEN** Node inventory is enabled
- **THEN** only the k8s-inventory ServiceAccount SHALL be granted Nodes
  get/list/watch
- **AND** host agents and netprobe SHALL NOT receive Kubernetes API credentials

### Requirement: Node watching is off where Nodes RBAC is not granted
A deployment of the collector SHALL NOT start the Node informer unless its
ServiceAccount is granted Nodes get/list/watch. The Node informer participates
in the startup cache sync, so a Forbidden List blocks readiness indefinitely
and stops the endpoint snapshots that deployment already published. The
`serviceradar-k8s-edge` chart grants only services and endpointslices, and
supports namespace-scoped RBAC in which cluster-scoped Nodes cannot be granted
at all, so it SHALL set `K8S_INVENTORY_NODES` to false.

#### Scenario: Edge chart keeps publishing endpoints
- **WHEN** the `serviceradar-k8s-edge` chart is installed or upgraded to an
  image that supports Node watching
- **THEN** the inventory container SHALL run with Node watching disabled
- **AND** the collector SHALL become ready and continue publishing endpoint
  snapshots

### Requirement: Node inventory persistence
EventWriter SHALL upsert each node snapshot into `platform.k8s_nodes_current`
and SHALL soft-delete rows for that cluster that are absent from the snapshot.

#### Scenario: Snapshot replaces prior generation
- **WHEN** a snapshot for cluster `demo` contains node `node-worker-1.example.com`
  and omits a previously current node
- **THEN** the current table SHALL contain the listed node
- **AND** the omitted node SHALL have `deleted_at` set

### Requirement: Ready condition transition events
When a persisted Node's `Ready` condition flips, the system SHALL emit an
internal log event `node.not_ready` (False) or `node.ready` (True) and SHALL
NOT deliver a notification from the EventWriter processor.

#### Scenario: Node becomes NotReady
- **WHEN** a node's stored `ready` value changes from true to false
- **THEN** the system SHALL emit `node.not_ready` with node name, cluster id,
  role, and Ready reason
- **AND** the processor SHALL NOT call a Discord or webhook transport

#### Scenario: Node recovers
- **WHEN** a node's stored `ready` value changes from false to true
- **THEN** the system SHALL emit `node.ready` for the same node identity

#### Scenario: Unchanged Ready is silent
- **WHEN** a snapshot repeats the same `ready` value for a node
- **THEN** the system SHALL NOT emit a readiness event for that node

### Requirement: Public-endpoints ingest stays isolated
EventWriter SHALL continue to ingest `inventory.k8s.public_endpoints` with the
public-endpoints processor and SHALL NOT parse node snapshots with that
processor.

#### Scenario: Node snapshot does not hit public-endpoints processor
- **WHEN** a message is published on `inventory.k8s.nodes`
- **THEN** the k8s-nodes processor SHALL handle it
- **AND** the public-endpoints processor SHALL NOT treat it as a public
  endpoint snapshot
