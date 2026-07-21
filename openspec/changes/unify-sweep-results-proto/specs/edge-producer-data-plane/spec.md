# edge-producer-data-plane Delta

## ADDED Requirements

### Requirement: Durable edge producers use one agent-owned record sink
All durable edge producers SHALL use one agent-owned record sink. Built-in
collectors, Wasm plugins, native add-ons, and embedded agent-side integrations
SHALL submit persistent observations, telemetry, inventory,
findings, traces, events, and results through one agent-owned durable record
sink. Producers SHALL NOT construct edge transport frames, receive broker or
database credentials, choose NATS subjects/streams/partitions, stamp trusted
agent or network-scope provenance, select traffic class, or write CNPG directly.
The command/execution plane, coalescible ephemeral state plane, and blob/media
plane SHALL remain separate from this durable record plane.

#### Scenario: A plugin emits a durable finding
- **GIVEN** a plugin assignment grants an approved finding output contract
- **WHEN** the plugin submits a bounded canonical finding
- **THEN** the agent-owned sink SHALL validate and durably spool it through the
  shared producer data plane
- **AND** the plugin SHALL receive no transport frame, subject, broker
  credential, or database destination

#### Scenario: A plugin emits runtime health
- **WHEN** a plugin reports a bounded coalescible health/status update that is
  explicitly classified ephemeral
- **THEN** the runtime MAY use the existing status path
- **AND** that update SHALL NOT be described as crash-safe durable telemetry

#### Scenario: A producer creates a large artifact
- **WHEN** a producer creates packet-capture, media, archive, or other opaque
  artifact bytes
- **THEN** those bytes SHALL use the separately authorized blob/media contract
- **AND** the record plane MAY carry only bounded immutable references and
  lifecycle/audit records

### Requirement: Output contracts are approved as complete immutable bundles
The deployment SHALL maintain a versioned output-contract registry shared by
assignment compilation, the agent sink, gateway readiness/routing, and
EventWriter. An immutable contract bundle SHALL bind contract ID/version,
encoding and schema canonicalization, unknown-field policy, bounded validator,
authoritative-field rules, deterministic domain identity and revision/merge
semantics, platform partition rule, cost model, projector engine/configuration,
retention/data classification, and error policy. Its exact digest and registry
epoch SHALL be bound into every accepted record and retained through the maximum
producer-retry, agent-offline, spool, JetStream replay, DLQ, and redrive horizon.

Package metadata MAY request approved outputs and declarative processor
contributions, but SHALL NOT choose subjects, streams, consumers, traffic class,
database tables/DDL, executable Core processors, or arbitrary subject filters.
A producer grant SHALL become ready only when agent, gateway, route map, and
required projector have compatible registry state.

#### Scenario: Package requests an unapproved output
- **WHEN** a package requests or submits a contract absent from its effective
  assignment grant
- **THEN** the agent SHALL reject it before local spool acceptance
- **AND** no fallback generic JSON, subject, or dynamic database projection
  SHALL be created

#### Scenario: Deployment components disagree on registry epoch
- **GIVEN** the agent can encode a contract but the gateway route or EventWriter
  projector is not ready for its exact bundle
- **WHEN** the scheduler evaluates a new producer assignment
- **THEN** the assignment SHALL remain not ready or paused
- **AND** the mismatch SHALL NOT be converted into a fleet-wide poison stream

#### Scenario: A contract is retired normally
- **WHEN** a newer contract version replaces an old version without a security
  incident
- **THEN** new grants SHALL use the new bundle while immutable old backlog MAY
  drain through the pinned historical bundle
- **AND** the historical bundle SHALL remain resolvable until all supported
  retry/replay/redrive horizons close

#### Scenario: A contract is revoked for compromise
- **WHEN** a contract, package, validator, or projector is security-revoked
- **THEN** new production and delivery of matching records SHALL stop fail-closed
- **AND** matching backlog SHALL be held or quarantined until an operator
  authorizes a fixed safe bundle, redrive, or explicit waiver

### Requirement: Producer provenance and authority are host-attested
Trusted producer provenance and authority SHALL be host-attested. Producer
instance, package digest, assignment, run, source/coverage scope,
network scope, agent identity, route profile, traffic class, and cost metadata
SHALL be derived or verified by the trusted agent sink from host-issued handles,
the effective grant, and control-plane-signed capabilities. Caller-selected
identifiers SHALL NOT create identity, capability, routing, or quota namespaces.
Output permission SHALL NOT grant network scanning, raw-socket, filesystem, HTTP,
credential, command, or target access; those capabilities SHALL be authorized
separately by the command/assignment plane.

Carrier provenance SHALL NOT make opaque payload claims authoritative.
EventWriter SHALL compare or replace body-level agent, package, source, network
scope, assignment/run, target/range, and traffic-class claims using the trusted
envelope/grant before side effects.

#### Scenario: A plugin claims another network scope and lower cost
- **WHEN** a plugin body or submission metadata claims another scope, route,
  traffic class, partition, or artificially low projected cost
- **THEN** the agent SHALL ignore/replace non-authoritative metadata or reject
  the record before spool acceptance
- **AND** EventWriter SHALL independently recompute the approved cost and
  validate decoded authoritative fields before projection

#### Scenario: A scanner output lacks scan authority
- **GIVEN** a package has permission to emit a scan-result contract but no valid
  target/range collection capability
- **WHEN** it attempts to report or initiate a scan
- **THEN** output permission SHALL NOT authorize the probe or make the target
  claims authoritative
- **AND** the record SHALL be rejected or retained as non-authoritative audit
  according to the approved contract

### Requirement: Local acceptance transfers ownership crash-safely
A successful local producer receipt SHALL mean the exact canonical bytes,
approved contract and provenance, stable semantic identity, and producer
idempotency binding are committed to the common crash-safe agent spool. It SHALL
NOT mean gateway, JetStream, EventWriter, or database commit. A retryable
`WOULD_BLOCK`, cancellation with known no-commit, or permanent rejection SHALL
mean ownership was not transferred and the producer remains responsible.

The sink SHALL atomically bind `(package digest, producer assignment,
host-issued run, output contract, producer idempotency key)` to event ID, body
digest, and durable receipt with the spool append. It SHALL retain this binding
for the declared retry horizon after spool reclamation, support receipt lookup
after an uncertain timeout, and reject the same key with different bytes as an
integrity conflict.

#### Scenario: Agent crashes after fsync but before replying
- **WHEN** a producer retries the same key after the agent durably appended the
  record but the success response was lost
- **THEN** receipt lookup or retry SHALL return the original event/receipt
  identity
- **AND** a second semantic record SHALL NOT be created

#### Scenario: Producer reuses a key for changed bytes
- **WHEN** one assignment/run/contract key is submitted with a different body
  digest
- **THEN** the sink SHALL return a permanent integrity error
- **AND** the original durable binding SHALL remain immutable

### Requirement: Producer pressure and fairness are bounded
Every grant SHALL bound record/frame/run bytes and counts, rate, concurrent
runs, pages, checkpoints, terminal attempts, outstanding spool bytes, retained
idempotency entries, and contract-specific expansion/write cost. The agent SHALL
run an approved bounded validator/cost engine before spooling or charge the
contract's fixed worst-case grant cost. Retryable pressure SHALL be distinct from
permanent size, schema, capability, revocation, and quota errors and SHALL expose
bounded retry-after or credit notification.

Byte-based fair scheduling SHALL include network scope, agent, producer
assignment, run/execution, and immutable traffic class. A producer SHALL NOT
promote itself, create a lane, consume the recovery floor, or monopolize another
producer. A source incapable of honoring backpressure SHALL be explicitly lossy
or loss-audited and SHALL NOT be advertised as durable.

#### Scenario: A huge inventory run shares an agent with an interactive check
- **WHEN** the inventory run exhausts its bulk credits or spool quota
- **THEN** it SHALL receive `WOULD_BLOCK` or admission deferral
- **AND** the interactive check and recovery lane SHALL continue within their
  reserved bounds

#### Scenario: A Wasm guest busy-loops on backpressure
- **WHEN** a guest repeatedly ignores `WOULD_BLOCK` or credit notification
- **THEN** the runtime SHALL pause, fuel-limit, or terminate that producer
- **AND** already accepted records and other producers' reserved capacity SHALL
  remain intact

### Requirement: Delivery topology is finite and platform-owned
The platform SHALL own a finite set of route profiles and immutable traffic
classes. A delivery lane SHALL be one route-profile/traffic-class pair plus a
separately reserved recovery lane. Lane, subject, physical stream, connection,
consumer, process, and RAFT-group cardinality SHALL NOT grow with payload kind,
package, plugin, integration, or output-contract count. V1 SHALL begin with one
`durable-records-v1` route profile and disjoint bulk/interactive physical
streams; another profile requires an explicit benchmarked platform change.

#### Scenario: A package defines many output contracts
- **WHEN** thousands of approved contracts share the durable record plane
- **THEN** trusted contract headers SHALL dispatch them over the finite route map
- **AND** the deployment SHALL NOT create thousands of lanes, subjects, streams,
  consumers, connections, processes, or RAFT groups

#### Scenario: Bulk transport is blocked
- **WHEN** a bulk lane exhausts its HTTP/2, publisher, stream, or database credits
- **THEN** separately pooled interactive and recovery lanes SHALL continue
- **AND** no unresolved bulk sequence SHALL be skipped or promoted

### Requirement: Run and snapshot lifecycles are bounded and explicit
A finite producer run SHALL use host-issued start, independently useful data,
bounded checkpoint, and complete/partial/aborted terminal identities. A
perpetual producer SHALL rotate bounded epochs. RPC close, producer exit, or the
last received page SHALL NOT imply completion.

Atomic snapshot pages SHALL be staged immutably by assignment-authorized source
instance and scheduler-owned generation without current-state or absence side
effects. A terminal MAY wait pending until every declared page ordinal/hash and
object-key uniqueness check succeeds and its bounded ordered Merkle/checkpoint
root validates. Activation SHALL atomically fence older generations and swap the
source's current snapshot pointer. Conflicting pages/terminals, abort-after-
complete, and late older terminals SHALL NOT replace current state; abandoned
staging SHALL have bounded repair retention and garbage collection.

Absence/deletion SHALL require a complete terminal with an assignment-scoped
provider snapshot token/revision or contract-specific consistency proof and
exact coverage scope. Without that proof, the run SHALL be upsert-only.

#### Scenario: Terminal arrives before one page
- **WHEN** a snapshot terminal arrives before all pages named by its root
- **THEN** the terminal SHALL remain pending and current inventory SHALL remain
  unchanged
- **AND** activation MAY occur only after the missing page commits and the full
  root validates

#### Scenario: Provider changes during pagination
- **GIVEN** received pages are individually valid but no consistent provider
  snapshot token/revision or equivalent proof exists
- **WHEN** the run terminates successfully
- **THEN** its records MAY upsert observed objects
- **AND** it SHALL NOT infer absence or delete previously current objects

#### Scenario: A stale complete terminal arrives late
- **WHEN** an older generation completes after a newer generation became current
- **THEN** the older terminal SHALL NOT move the current pointer backward
- **AND** conflicting same-generation evidence SHALL be quarantined as an
  integrity failure

### Requirement: Wasm and native adapters expose the common durability contract
The Wasm runtime SHALL expose a versioned binary host ABI and SDK for open,
publish, checkpoint, commit, abort, receipt lookup, and credit notification.
Canonical bytes SHALL cross guest memory through one bounded copy without
protobuf-to-base64-to-JSON wrapping, and the guest SHALL NOT see
`EdgeResultFrame` or trusted routing/provenance fields.

Native add-ons SHALL use an assignment-authenticated bidirectional record relay
with byte/frame credits, host-issued session nonce, stale-session fencing,
resume watermark, and cumulative ACK only after common-spool fsync. An add-on
SHALL retain uncertain records and retry with stable producer keys. Durable
native telemetry and OTLP output SHALL migrate to this adapter; only explicitly
ephemeral runtime counters MAY remain on lossy queues.

#### Scenario: Wasm publish times out during group commit
- **WHEN** the host call times out or is cancelled while fsync outcome is
  uncertain
- **THEN** the guest SHALL retry or query with the same producer key
- **AND** the host SHALL return the original receipt if ownership transferred

#### Scenario: Native add-on reconnects after local ACK loss
- **WHEN** an add-on reconnects with an uncertain last record
- **THEN** it SHALL open a fresh fenced session and resume from the last durable
  watermark
- **AND** stable producer keys SHALL prevent record loss or duplicate domain
  side effects

### Requirement: Projection is platform-owned and replay-safe
EventWriter SHALL dispatch by exact trusted `(route profile, contract ID,
version, complete contract digest)` and use only a compiled platform projector or
an approved bounded declarative processor contribution. Packages SHALL NOT
execute BEAM/native/JavaScript code, SQL, DDL, or choose physical storage during
ingestion. Deterministic validation/projection failures SHALL use the durable DLQ
policy; deployment-not-ready versions SHALL pause rather than poison valid data.

Every contract SHALL define domain idempotency and authoritative-versus-derived
status. A producer grant SHALL prevent the same fact from being emitted
simultaneously as typed output, extension output, `MetricBatch`, OCSF,
`plugin_result` JSON, or a lossy copy unless one platform-owned idempotent
derivation is the sole owner of the secondary representation.

#### Scenario: Extension record selects a package subject and SQL table
- **WHEN** package metadata attempts to provide a subject filter, SQL, DDL,
  executable processor, or destination table
- **THEN** import or contract approval SHALL reject those transport/storage
  authorities
- **AND** no dynamic EventWriter subscription or database mutation path SHALL be
  created

#### Scenario: One canonical record needs a compatibility metric
- **WHEN** an existing consumer cannot yet read the canonical contract
- **THEN** one platform-owned idempotent downstream normalizer MAY derive a
  bounded correlated metric
- **AND** the producer SHALL NOT emit both authoritative forms

### Requirement: Durable records become subscribable before CNPG persistence
Every persistent agent-originated record SHALL obtain an authoritative
JetStream PubAck before the gateway acknowledges its edge spool sequence, and
CNPG projection SHALL occur only through EventWriter. The record SHALL remain
available to authorized real-time consumers before database persistence. Fixed
bounded record batches and manifests SHALL remain JetStream stream records;
oversize output SHALL be contract-paged, rejected, or quarantined and SHALL NOT
be silently diverted to Object Store.

#### Scenario: Native add-on metric is accepted
- **WHEN** the gateway obtains the authoritative PubAck for a canonical metric
  record
- **THEN** real-time consumers MAY subscribe concurrently with EventWriter
- **AND** no direct agent, add-on, gateway, or Core write SHALL bypass JetStream

#### Scenario: JetStream is unavailable
- **WHEN** the gateway cannot obtain an authoritative PubAck
- **THEN** it SHALL withhold the edge ACK and the agent SHALL retain the frame
- **AND** local producer pressure SHALL eventually receive bounded admission or
  `WOULD_BLOCK` rather than acknowledged loss

### Requirement: Cluster-local producers use governed service ingress
Cluster-local producers SHALL use governed service ingress. A cluster-local
producer MAY use the same canonical contract/projector registry
without hairpinning through an agent/gateway, but it SHALL publish through an
attested service identity and contract-scoped governed JetStream publisher that
observes the same envelope, routing, cost, idempotency, and PubAck rules. It
SHALL NOT claim agent provenance. A transactional outbox MAY be used only when
the record's system of record is the same operational transaction; metrics and
telemetry SHALL remain JetStream-first.

#### Scenario: Cluster-local telemetry producer publishes a metric
- **WHEN** a cluster service emits persistent telemetry
- **THEN** its service-attested publisher SHALL place the canonical record in
  JetStream before EventWriter projection
- **AND** it SHALL NOT use an operational database outbox as a database-first
  telemetry path or impersonate an edge agent
