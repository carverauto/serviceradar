## ADDED Requirements

### Requirement: Kubernetes Node current-state inventory
The system SHALL publish a current-state inventory of Kubernetes Nodes from
the in-cluster `serviceradar-k8s-inventory` collector, including each Node's
name, cluster id, role (control-plane or worker), and `Ready` condition, on
JetStream subject `inventory.k8s.nodes` of stream `k8s_inventory`. That
subject SHALL NOT be operator-configurable: EventWriter's stream definition
and Broadway subject matcher both hardcode it, so any other value would
publish where nothing consumes.

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

### Requirement: Node watching is opt-in
The collector SHALL default `K8S_INVENTORY_NODES` to false and SHALL start the
Node informer only when a deployment asks for it. The Node informer
participates in the startup cache sync, so where Nodes RBAC is absent a
Forbidden List blocks readiness indefinitely and stops the endpoint snapshots
that deployment already published. `helm/serviceradar` renders the variable
explicitly from `k8sInventory.nodes.enabled`, so an opt-in default changes
nothing there; `helm/serviceradar-k8s-edge` sets no such variable and relies
on the collector default plus the `agent_spool` refusal below. An un-updated
manifest keeps its previous behaviour rather than blocking on cache sync.

#### Scenario: A manifest that predates node watching keeps working
- **WHEN** a collector runs from a manifest that sets no `K8S_INVENTORY_NODES`
  and whose ServiceAccount has no Nodes RBAC
- **THEN** the collector SHALL NOT start the Node informer
- **AND** it SHALL become ready and continue publishing endpoint snapshots

#### Scenario: Edge chart keeps publishing endpoints
- **GIVEN** the `serviceradar-k8s-edge` chart, whose inventory RBAC grants no
  Nodes access and whose publish mode is `agent_spool`
- **WHEN** it is installed or upgraded to an image that supports Node watching
- **THEN** the inventory container SHALL run with Node watching disabled
- **AND** the collector SHALL become ready and continue publishing endpoint
  snapshots

### Requirement: Watching Nodes SHALL NOT starve endpoint publishing
The collector's periodic resync SHALL perform a rebuild rather than restart
the debounce timer, so a rebuild happens at least once per resync period
regardless of watch-event rate. The rebuild debounce is resetting and has no
max wait, and Node status is a cluster-size-proportional event source that
kubelet emits continuously, so routing Node events through the same notify
channel as Services and EndpointSlices would otherwise let a large cluster
hold the timer open indefinitely and stop the public-endpoint snapshots that
deployment already published.

#### Scenario: Sustained Node churn still publishes endpoints
- **GIVEN** watch events arriving faster than the debounce interval
- **WHEN** the resync period elapses
- **THEN** the collector SHALL rebuild and publish
- **AND** the public-endpoint snapshot SHALL NOT be starved by node churn

### Requirement: Node publishing is refused on a subject-blind sink
The collector SHALL reject a configuration that enables Node watching while
`PUBLISH_MODE` is `agent_spool`. That sink ignores the publish subject and
keeps a single snapshot file, so a node snapshot would overwrite the endpoint
snapshot the agent republishes; the endpoints processor accepts a node
snapshot as an endpoint snapshot with zero endpoints and soft-deletes every
public endpoint row for that cluster, silently.

#### Scenario: Nodes plus agent spool is a startup error
- **WHEN** a collector is configured with `PUBLISH_MODE=agent_spool` and
  `K8S_INVENTORY_NODES=true`
- **THEN** configuration validation SHALL fail with an error naming the
  conflict
- **AND** the collector SHALL NOT publish a node snapshot to the spool

### Requirement: Node inventory persistence
EventWriter SHALL upsert each node snapshot into `platform.k8s_nodes_current`
and SHALL soft-delete rows for that cluster that are absent from the snapshot.
It SHALL accept only snapshots whose `generated_at` is newer than the cluster
watermark in `platform.k8s_node_snapshots`, including for empty snapshots.
The watermark and node writes SHALL share the snapshot transaction.

#### Scenario: Snapshot replaces prior generation
- **WHEN** a snapshot for cluster `demo` contains node `node-worker-1.example.com`
  and omits a previously current node
- **THEN** the current table SHALL contain the listed node
- **AND** the omitted node SHALL have `deleted_at` set

#### Scenario: A stale snapshot cannot restore old readiness
- **GIVEN** a newer snapshot has already committed for a cluster
- **WHEN** an equal or older snapshot is delivered
- **THEN** it SHALL change neither node rows nor the watermark
- **AND** it SHALL emit no readiness or deletion-recovery events

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

#### Scenario: A node seen for the first time does not page
- **WHEN** a snapshot contains a NotReady node that has no persisted `ready`
  value for that cluster
- **THEN** the system SHALL persist it and SHALL NOT emit `node.not_ready`
- **AND** a later flip to Ready and back SHALL page normally

#### Scenario: A NotReady node removed from the cluster clears its incident
- **GIVEN** a persisted node whose stored `ready` value is false
- **WHEN** the next snapshot omits that node
- **THEN** the system SHALL emit `node.ready` for it so the open incident
  clears
- **AND** the event message SHALL say the node was removed from the cluster
  rather than that it recovered

### Requirement: A readiness event that cannot be published SHALL NOT be consumed
The processor SHALL abort the transaction that applied a snapshot when
publishing a `node.not_ready` or `node.ready` event fails, rather than logging
the failure and committing. Success SHALL require synchronous stateful
evaluation, not queue admission alone. Promotion-rule load, initial stateful-rule
load, incident-state restoration, alert lifecycle, and required incident-state
persistence failures SHALL propagate to the snapshot caller. A failed state
write SHALL retain the pending snapshot and flush flag for retry.
Committing the upserted row while dropping the
event makes the transition unrecoverable: the next snapshot compares the new `ready` value
against itself, emits nothing, and the incident never opens. The apply is
idempotent, so aborting lets JetStream redeliver against the prior state, and
a persistently failing message surfaces through max-deliver instead of
silently losing a page.

#### Scenario: A failed publish is redelivered, not swallowed
- **GIVEN** a snapshot in which a node flips from Ready to NotReady
- **WHEN** publishing the `node.not_ready` event returns an error
- **THEN** the snapshot transaction SHALL roll back, leaving the stored
  `ready` value unchanged
- **AND** the processor SHALL report the failure so the message is redelivered

#### Scenario: Failed incident-state persistence is not acknowledged
- **GIVEN** a readiness event creates an incident but its state write fails
- **WHEN** synchronous evaluation returns that persistence failure
- **THEN** the node writes and cluster watermark SHALL roll back
- **AND** the engine SHALL retain the incident snapshot with its flush pending

### Requirement: Public-endpoints ingest stays isolated
EventWriter SHALL continue to ingest `inventory.k8s.public_endpoints` with the
public-endpoints processor and SHALL NOT parse node snapshots with that
processor.

#### Scenario: Node snapshot does not hit public-endpoints processor
- **WHEN** a message is published on `inventory.k8s.nodes`
- **THEN** the k8s-nodes processor SHALL handle it
- **AND** the public-endpoints processor SHALL NOT treat it as a public
  endpoint snapshot
