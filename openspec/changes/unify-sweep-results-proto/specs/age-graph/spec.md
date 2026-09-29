# age-graph Delta

## MODIFIED Requirements

### Requirement: MTR Path Graph Projection
The MTR EventWriter path SHALL project committed canonical traces into the
`platform_graph` Apache AGE graph as replay-safe `MTR_PATH` edges between Device
or HopNode vertices through an atomically created, idempotent graph outbox.
Moving ingestion from legacy JSON SHALL preserve topology semantics and SHALL NOT
introduce a second graph writer or acknowledge a source transaction without its
required outbox row. Each outbox row SHALL be keyed by
`(network_scope_id, trace_id, graph_schema_version)`, carry the immutable source
`traffic_class`, and retain a bounded immutable graph-projection payload or a
content-addressed non-hypertable payload that remains readable independently of
raw Timescale chunks. A bounded idempotent normalizer SHALL expand each parent
outbox row into deterministic append-only vertex-observation and edge-observation
tasks with expected count/digest. Each task SHALL preserve source traffic class
and use a stable owner shard derived from its network-scope-safe topology
identity plus an immutable graph owner-map version. The map's hash function and
shard count SHALL be immutable within one graph schema/map version. Exactly one
fenced lease SHALL mutate an `(owner_map_version, owner_shard)` at a time;
projectors SHALL use class-aware subqueues, weighted-fair selection, and the
shared result-pool credit controller with a reserved interactive floor.

#### Scenario: MTR path edges created from trace data
- **WHEN** a canonical MTR trace transaction commits
- **THEN** the source transaction SHALL atomically insert the trace/hops and one
  unique pending outbox row before its JetStream ACK
- **AND** a normalizer SHALL atomically create deterministic vertex/edge tasks
  plus their count/digest before marking the parent expanded
- **AND** stable-owner projectors SHALL MERGE each consecutive responding hop
  pair as one replay-safe `MTR_PATH` edge and atomically mark every represented
  task projected with its AGE mutation and relational watermark
- **AND** the parent SHALL become projected only after every expected task is
  durably resolved
- **AND** edge properties SHALL include agent ID, average RTT, loss, last seen,
  protocol, and stable source trace identity
- **AND** hop IPs matching an existing Device in the same `network_scope_id`
  SHALL reuse that Device
- **AND** unknown hop IPs SHALL use network-scope-prefixed HopNode vertices with
  IP, hostname, ASN, and ASN-organization properties

#### Scenario: Trace event is redelivered
- **WHEN** an already committed canonical trace is replayed
- **THEN** graph vertices/edges SHALL not duplicate
- **AND** the graph projection SHALL remain attributable to the stable network
  scope and trace identity

#### Scenario: Graph projection fails after source commit
- **GIVEN** trace/hop rows and their outbox row committed successfully
- **WHEN** AGE projection fails or the projector crashes before marking success
- **THEN** the outbox row SHALL remain pending and retryable with observable
  attempt/error/age state
- **AND** replay of the source event SHALL NOT short-circuit away the required
  graph repair

#### Scenario: Raw trace chunks retire before graph repair
- **GIVEN** an unresolved graph projection outlives the raw MTR hypertable chunk
  containing its source trace and hops
- **WHEN** raw retention retires that chunk
- **THEN** the pending outbox row's immutable retained projection payload SHALL
  remain sufficient to complete or audit graph projection
- **AND** retention SHALL NOT pin an entire Timescale chunk for one failed graph
  row or leave a dangling outbox pointer

#### Scenario: Correctness partition retires with unresolved graph work
- **GIVEN** an unresolved parent or topology task still owns inline projection
  input when its ordinary metadata partition reaches the retirement watermark
- **WHEN** the partition is prepared for detach/drop
- **THEN** one transaction SHALL copy the complete bounded input into held
  storage or pin its checksummed content-addressed payload and create the
  corresponding `correctness_hold`
- **AND** a digest or source pointer without retained projection bytes SHALL NOT
  authorize partition retirement

#### Scenario: Two network scopes use the same private hop address
- **GIVEN** two sites with distinct `network_scope_id` values observe the same
  RFC1918 hop address
- **WHEN** their traces are projected
- **THEN** Device, HopNode, and `MTR_PATH` identities SHALL remain scope-distinct
- **AND** no edge, property update, query, orphan cleanup, or prune SHALL cross
  the authoritative network scope

The `(observed_at, trace_id)` ordering SHALL compare RAW NANOSECONDS. It SHALL NOT consume the
nanosecond-to-microsecond canonicalization that
`freeze-edge-record-v1-abi`'s "Nanosecond time is canonicalized to microseconds only at the
projection boundary" requires for the `TIMESTAMPTZ` storage coordinates. The graph is not bound
by `timestamptz` microsecond resolution, so canonicalizing here would collapse observations
inside one microsecond into ties broken arbitrarily by `trace_id` -- replacing a determinate
order with an arbitrary one, in the comparison that exists to stop properties moving backward.

#### Scenario: Two observations inside one microsecond still order determinately
- **WHEN** two traces for the same edge carry `observed_at` values in the same microsecond,
  differing only in their sub-microsecond digits
- **THEN** the newer one SHALL win the property update
- **AND** the decision SHALL NOT fall through to a `trace_id` comparison, because the
  timestamps are compared at nanosecond resolution and are not equal

#### Scenario: Older trace projects after a newer trace
- **GIVEN** one network-scope/agent/protocol/path edge already has a newer
  observation
- **WHEN** an older trace is projected late
- **THEN** `(observed_at, trace_id)` comparison SHALL prevent RTT, loss,
  hostname, ASN, and last-observed properties from moving backward
- **AND** replay SHALL remain idempotent for the
  network-scope/agent/protocol/ordered-endpoints/path-variant edge identity

#### Scenario: Bulk graph backlog competes with interactive work
- **GIVEN** graph outbox rows from both bulk and interactive source classes are
  pending
- **WHEN** fenced projectors claim bounded batches and reserve result-pool
  credits
- **THEN** disjoint class-aware claim queues and weighted-fair selection SHALL
  preserve a bounded interactive credit floor and drain-delay objective
- **AND** an outbox row, retry, repair, or replay SHALL retain the immutable
  traffic class of its source event and SHALL NOT promote bulk work into the
  interactive reserve
- **AND** a projector SHALL mark only rows covered by its current claim lease in
  the same transaction as their fully represented AGE mutations

#### Scenario: Many traces share a backbone hop and edge
- **GIVEN** concurrent traces contain the same network-scope-safe vertex or edge
- **WHEN** their graph observations become eligible
- **THEN** every observation for that topology identity SHALL route to the same
  stable owner shard and one live fenced owner
- **AND** the owner SHALL coalesce a bounded fold window into one deterministic
  monotonic AGE/watermark mutation without cross-worker row contention
- **AND** dependent edge tasks SHALL wait until their endpoint vertex tasks are
  committed

#### Scenario: Graph owner shard count changes
- **WHEN** operators need a different owner hash function or shard count
- **THEN** normalization SHALL pause behind a versioned owner-map barrier until
  every old task is resolved or atomically migrated with its payload/watermark and
  old owner leases are fenced
- **AND** only then SHALL the new map accept tasks, while map history remains
  available through repair, prune, and rollback horizons
- **AND** the topology-identity-keyed relational watermark SHALL atomically move
  its stored owner-map version/shard under the old/new fence
- **AND** old and new owners SHALL NOT mutate the same topology identity
  concurrently

#### Scenario: Pruned edge receives delayed old outbox work
- **GIVEN** an AGE edge was TTL-pruned after a newer observation
- **WHEN** a delayed/redriven older trace reaches graph projection
- **THEN** a network-scope-safe relational edge watermark/prune tombstone retained
  through the replay/redrive horizon SHALL prevent edge recreation or regression
- **AND** an already-expired observation SHALL be marked projected-expired without
  recreating stale topology

#### Scenario: Stale MTR path edges pruned
- **WHEN** an `MTR_PATH` edge is older than the configured topology TTL
- **THEN** one fenced PostgreSQL transaction SHALL advance the scope-safe
  watermark/prune tombstone and remove or retire the AGE edge atomically
- **AND** orphaned HopNode cleanup SHALL retain its existing behavior
- **AND** pruning and orphan cleanup SHALL be scoped by authoritative network
  scope and use the same stable owner shard/fence as concurrent projection

#### Scenario: Network-scope graph schema is migrated
- **GIVEN** retained traces and an unscoped legacy graph exist
- **WHEN** the graph-v2 migration begins
- **THEN** the legacy direct writer SHALL stop at a barrier and one canonical
  outbox projector SHALL maintain separate idempotent v1/v2 projection statuses
  through the rollback window
- **AND** reads SHALL switch only after retained/new-history parity and SHALL be
  able to roll back until v1 projection is deliberately retired
- **AND** unscoped legacy graph identities SHALL be quarantined when an
  authoritative network scope cannot be backfilled without ambiguity
