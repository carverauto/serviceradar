# nats-tenant-isolation Delta

## MODIFIED Requirements

### Requirement: Tenant Channel Prefixing

Runtime NATS subjects SHALL be fixed, versioned, installation-local contracts;
they SHALL NOT interpolate a SaaS customer/tenant slug, caller-supplied identity,
or `network_scope_id`. The ServiceRadar runtime is one customer per installation,
including when an external SaaS control plane provisions the installation.
`network_scope_id` SHALL remain authenticated envelope metadata used to
distinguish sites/address spaces, including overlapping RFC1918 networks, and
SHALL NOT create a broker namespace, dedicated physical stream, database schema,
or capacity cell. It MAY be used within shared installation-local fairness and
admission controls so one site/address space cannot monopolize the installation.

#### Scenario: Runtime publisher selects a subject

- **GIVEN** a publisher has a typed signal and authenticated installation-local
  credentials
- **WHEN** it selects the signal's configured subject
- **THEN** it SHALL use that fixed versioned subject without a customer prefix
- **AND** no body, caller, site, agent, or network-scope value SHALL alter the
  credential's subject authority

#### Scenario: Result publication does not interpolate identity

- **GIVEN** an authenticated agent reports a bulk durable record for logical
  partition `p07`
- **WHEN** the gateway selects its canonical subject
- **THEN** it SHALL publish to `telemetry.edge-record.v1.bulk.p07`
- **AND** neither caller text nor `network_scope_id` SHALL alter that subject

### Requirement: NATS Account Isolation

One installation SHALL use one configured NATS security/durability authority
with least-privilege component credentials and finite installation-level account,
stream, storage, consumer, connection, and admission quotas. The runtime SHALL
NOT provision accounts, credentials, streams, or capacity cells per customer,
network scope, agent, or execution. SaaS customer isolation SHALL come from
separate provisioned clusters, not an in-runtime account hierarchy.

#### Scenario: Component credentials attempt to widen authority

- **GIVEN** a component holds installation-scoped credentials
- **WHEN** it attempts a publish, subscribe, import, export, or mapping outside
  its exact configured subjects
- **THEN** NATS authorization SHALL reject the operation
- **AND** payload, header, site, agent, or network-scope values SHALL NOT widen
  the credential

#### Scenario: Installation contains several network scopes

- **GIVEN** one installation monitors several sites with overlapping addresses
- **WHEN** their `EdgeRecordV1` bytes enter JetStream
- **THEN** they SHALL share the bounded installation result-stream topology
- **AND** trusted `network_scope_id` SHALL keep their domain identities distinct
  without creating per-scope accounts, streams, or durables

### Requirement: JetStream Tenant Streams

JetStream streams SHALL capture fixed installation-local subject families for
durability and replay. All approved edge durable records SHALL use the traffic-class-
separated subjects and explicit physical-stream map defined by this change. A
consumer SHALL derive network scope, agent, and authorization identity from the
verified envelope/proof for its signal contract, never from a customer prefix.

#### Scenario: Installation event remains replayable

- **GIVEN** a configured event stream captures its fixed event subject family
- **WHEN** an installation-local event is published
- **THEN** it SHALL be persisted and available for replay without customer-
  prefix routing

#### Scenario: Record consumer receives a fixed subject

- **GIVEN** EventWriter pulls `telemetry.edge-record.v1.interactive.p11`
- **WHEN** it validates the persisted authoritative `EdgeRecordV1`
- **THEN** it SHALL derive the trusted network scope, agent, traffic class, and
  collection authority from that record and its signed grants
- **AND** it SHALL NOT interpret any subject token as customer identity

### Requirement: Per-tenant zen consumers

Zen consumers SHALL use bounded installation-scoped credentials and consumer
pools. They SHALL NOT require one process, connection, account, or durable per
customer or network scope, and SHALL NOT use cross-customer fallback consumers.

#### Scenario: Zen consumer processes an installation signal

- **GIVEN** a zen consumer has least-privilege installation credentials
- **WHEN** a configured log or event signal arrives
- **THEN** a bounded installation consumer pool SHALL process it
- **AND** its output SHALL remain in the same installation authority

### Requirement: Per-tenant db-event-writer ingestion

EventWriter SHALL run as an installation-scoped bounded worker pool using the
installation database role/schema and signal-specific identity. It SHALL NOT
select database schemas or spawn writers from a customer/tenant subject prefix.

#### Scenario: EventWriter persists an installation signal

- **WHEN** EventWriter validates and commits a configured signal
- **THEN** it SHALL write through the installation's bounded database pool and
  canonical schema
- **AND** subject text SHALL NOT select another database authority

### Requirement: Rule distribution via KV with tenant isolation

Rule distribution SHALL use installation-scoped KV buckets, credentials, and
watches. Rule identity and authorization SHALL be explicit installation-local
metadata and SHALL NOT depend on customer-prefixed bucket or subject names.

#### Scenario: Rule update propagates inside one installation

- **WHEN** an authorized administrator updates a promotion rule
- **THEN** the system SHALL publish it to the configured installation KV bucket
- **AND** the installation zen consumer SHALL receive it through its bounded
  watch

### Requirement: Backward Compatibility

Migration from legacy customer-prefixed subjects SHALL be bounded and explicit.
After the cutover barrier, runtime publishers and consumers SHALL use only fixed
installation-local contracts and SHALL NOT map unprefixed data to a synthetic
`default` customer identity.

#### Scenario: Legacy prefixed backlog exists at cutover

- **GIVEN** a declared legacy stream contains prefixed messages accepted before
  the cutover watermark
- **WHEN** a compatibility consumer drains that sealed backlog
- **THEN** it SHALL use retained trusted legacy authority metadata for audit and
  projection
- **AND** new runtime publication SHALL use only the fixed installation subjects

#### Scenario: Legacy prefix cannot be resolved safely

- **WHEN** a retained message cannot be mapped to the installation without
  ambiguity
- **THEN** migration SHALL quarantine it for audited repair
- **AND** SHALL NOT invent a `default` customer or widen database authority

## ADDED Requirements

### Requirement: Installation-local record streams are traffic-class isolated

The installation SHALL provision these versioned record subject families:

- `telemetry.edge-record.v1.bulk.pNN`
- `telemetry.edge-record.v1.interactive.pNN`
- `telemetry.edge-record-recovery.v1`
- `telemetry.edge-record-dlq.v1.bulk.pNN`
- `telemetry.edge-record-dlq.v1.interactive.pNN`

Bulk and interactive durable-record subjects SHALL use disjoint physical streams and
disjoint persistence durables. Result-DLQ subjects SHALL preserve the original
traffic class and SHALL also use disjoint physical capacity and consumers so a
bulk poison cohort cannot consume or queue ahead of the interactive reserve.
The recovery stream SHALL have separate unborrowable storage, PubAck, and
consumer capacity. The installation SHALL NOT create a durable, connection,
process, account, or physical stream per network scope, agent, producer
assignment, run/execution, output contract, package, or logical partition.

#### Scenario: Bulk catch-up overlaps an interactive record

- **GIVEN** bulk edge-record streams are draining an outage-sized backlog
- **WHEN** an authorized interactive durable record is published
- **THEN** it SHALL use an interactive physical stream and persistence durable
  that no bulk subject captures
- **AND** bulk work SHALL NOT borrow the configured interactive storage, PubAck,
  consumer, or database-credit floor

#### Scenario: Interactive poison is routed to its class reserve

- **GIVEN** an interactive source event is permanently invalid
- **WHEN** its bounded canonical DLQ wrapper is published
- **THEN** it SHALL use `telemetry.edge-record-dlq.v1.interactive.pNN` for the mapped
  logical partition
- **AND** neither initial routing nor redrive SHALL promote or demote its traffic
  class

### Requirement: The platform partition rule `network_scope_v1` is frozen

The installation SHALL evaluate exactly one platform partition rule, `network_scope_v1`, defined
by this requirement. The output-contract bundle pins the rule; every other rule identifier SHALL
be refused until the contract registry defines it, and a contract naming no rule SHALL be refused.

`network_scope_v1` SHALL apply ONLY when the resolved output-contract bundle explicitly pins it.
It is NOT a property of the durable-record route profile: partition rules are pinned per output
contract, and a bundle may instead pin a rule that hashes scope plus execution/shard, scope plus
agent and event ID, or source assignment plus run.

Its transcript SHALL be the raw `network_scope_id` bytes exactly as signed -- no domain prefix, no
length framing, and no concatenation with any other coordinate. The partition SHALL be
`FNV-1a/32(transcript) mod 64`, where FNV-1a/32 uses offset basis 2166136261 and prime 16777619,
and 64 is the fixed logical partition count.

Subject AUTHORITY and partition SELECTION are different things, and only the first is closed to
`network_scope_id`.

The rule DOES determine which `pNN` a record occupies, and `pNN` is part of the subject string --
saying otherwise would contradict this requirement's own transcript. What `network_scope_id` SHALL
NOT do is alter subject AUTHORITY: it SHALL NOT appear as a subject token, SHALL NOT prefix the
subject, SHALL NOT select or widen a credential's subject authority, and SHALL NOT change the
versioned family or the traffic class. Those are fixed by the route profile and the effective
grant before any partition is computed.

Within that already-fixed authority, the platform-owned rule selects the partition from
AUTHENTICATED outer context, exactly as a bulk durable record for logical partition `p07`
publishes to `telemetry.edge-record.v1.bulk.p07`. The existing prohibition on caller text or
`network_scope_id` altering that subject binds CALLER-SUPPLIED interpolation and credential
authority, not the platform rule that assigns `pNN` -- a record must land on some partition, and
the requirement above already names one.

An empty or absent `network_scope_id` SHALL be refused rather than mapped to partition 0, because
zero is a real partition and a default would place every unpopulated contract on one shard.

The recovery route profile carries no partition. It SHALL still name a defined rule, so that "an
unknown rule is refused" holds for every profile rather than for every profile except the one
nobody inspects.

The transcript, the hash, and the partition count SHALL be frozen together by committed
key-to-partition vectors and by route-level component-to-subject vectors. Changing any of the
three re-places every future record relative to the data already stored, and SHALL bump the
partition scheme version deliberately.

#### Scenario: A contract names an undefined partition rule

- **WHEN** a verified contract pins a rule this installation does not define
- **THEN** routing SHALL refuse the record
- **AND** SHALL NOT fall back to `network_scope_v1` or any other rule

#### Scenario: A recovery record names an undefined partition rule

- **GIVEN** the recovery profile computes no partition
- **WHEN** its contract pins an undefined rule
- **THEN** routing SHALL refuse it on the same terms as a partitioned profile

### Requirement: Logical record partitions map to explicit physical streams

The 64 stable logical partitions SHALL remain routing and locality metadata, not
exclusive application-worker ownership or implicit JetStream storage shards. A
versioned installation map SHALL assign every `(platform route profile, traffic class,
logical partition)` to exactly one authoritative physical stream. It MAY map
disjoint subject partitions onto additional stream/RAFT groups when benchmarked
write, storage, or recovery limits require it. Gateway and consumer readiness
SHALL use the same persisted map version and authority history.

#### Scenario: One physical stream reaches its benchmarked limit

- **GIVEN** logical partitions already provide consumer concurrency
- **WHEN** one stream leader, replica set, or storage volume reaches its safe
  write, recovery, or capacity limit
- **THEN** provisioning SHALL place disjoint logical partitions on additional
  physical streams
- **AND** the gateway SHALL set `Nats-Expected-Stream` to the unique mapped stream

#### Scenario: Subject ownership is missing or overlaps

- **WHEN** readiness detects that a logical record subject is captured by zero or
  more than one authoritative physical stream
- **THEN** the affected installation record path SHALL remain not ready
- **AND** gateways SHALL NOT accept v1 producer runs for that path

#### Scenario: A logical partition changes physical placement

- **WHEN** operators change a logical partition's physical stream mapping
- **THEN** admission SHALL stop, old-generation gateway leases SHALL be revoked or
  expired, and old subject authority SHALL be sealed before exactly one new
  authority becomes writable
- **AND** the sealed old consumer and immutable map/credential history SHALL
  remain available through final AckWait, redelivery, repair, and rollback
  watermarks

### Requirement: Record stream capacity is installation-admitted

The installation SHALL have aggregate and per-site/agent/producer-assignment/
run-or-execution/traffic-class
admission envelopes covering synchronized scheduled bursts, live traffic,
spool replay overlap, supported outage, worst-case catch-up, headers, replication,
and safety margin. Physical stream, account, disk, consumer, connection, and
PubAck limits SHALL cover the sum of admitted envelopes and worst-case hash skew.
Source-stream `MaxAge` and `MaxBytes` SHALL retain every acknowledged event
through the declared outage plus catch-up horizon; `DiscardNew` SHALL propagate
pressure before acknowledged data can expire or be evicted.

#### Scenario: New work exceeds the installation envelope

- **WHEN** a new or overlapping run/job would exceed its site/agent/producer/run budget
  or the installation spool, stream, catch-up, MTR, or database budget
- **THEN** the scheduler or gateway SHALL defer or reject the work before probing
  or publication
- **AND** it SHALL expose the exact deployment-local capacity reason

#### Scenario: Source retention cannot cover recovery

- **WHEN** a source stream's `MaxAge` is less than supported outage plus
  worst-case catch-up and safety margin
- **THEN** provisioning SHALL fail the v1 readiness gate
- **AND** the gateway SHALL NOT advertise the installation result path as ready

### Requirement: Persistence consumers acknowledge deliveries explicitly

Every result persistence durable SHALL use JetStream explicit per-message ACK
policy. It SHALL NOT use cumulative `AckAll`. Pull and transaction grouping MAY
be concurrent or out of delivery order, but a delivery SHALL be ACKed only after
the database transaction containing its independent ledger/domain effects commits.

#### Scenario: Earlier worker crashes after later delivery commits

- **GIVEN** a later delivery commits while an earlier delivery remains in flight
- **WHEN** the later worker acknowledges its result
- **THEN** only that delivery SHALL be acknowledged
- **AND** the earlier delivery SHALL redeliver without any committed event being
  applied twice

### Requirement: Result DLQ survives systemic poison and uses state-aware deletion

Each class-partitioned result DLQ SHALL have `MaxAge` disabled, finite `MaxBytes`,
production replication, strict subscribe permissions, access audit, encryption,
and separately reserved storage, PubAck, indexing, redrive, and delete capacity.
It SHALL NOT consume the recovery-control reserve. A bounded idempotent indexer
SHALL maintain `result_dlq_record`, keyed by stable DLQ ID and physical
stream/sequence, with immutable source provenance, original traffic class,
error cohort, redrive attempts/outcomes, waiver, audit actor/time, and final
state. Unknown or unindexed sequences SHALL NOT be deleted.

For a consumer poison record, the canonical DLQ wrapper SHALL preserve the exact
original `EdgeRecordV1` bytes and digest without reconstructing or duplicating
semantic fields in broker headers. It SHALL add only bounded DLQ/source placement
metadata including source stream/sequence, original delivery coordinates,
applicable delivery-proof audit, and error classification. A pre-primary gateway
rejection SHALL preserve the complete safely validated immutable record/proof
subset plus a full-frame fingerprint and trusted agent/spool/rejection
coordinates. The source delivery SHALL terminate only after the mapped DLQ
publication obtains PubAck.

#### Scenario: Poison event is copied

- **WHEN** a source result is permanently invalid
- **THEN** its class-partitioned DLQ record SHALL use a stable source-stream/
  sequence/checksum/error-class ID and preserve the exact immutable
  `EdgeRecordV1` bytes plus bounded source-placement/error metadata
- **AND** the source SHALL remain unresolved if the mapped DLQ cannot PubAck

#### Scenario: Poison rate indicates a systemic decoder failure

- **WHEN** a per-partition, per-class, or aggregate poison rate/ratio crosses its
  configured threshold
- **THEN** affected pulls and new gateway acceptance SHALL pause and page before
  the DLQ consumes its reserved capacity
- **AND** ordinary fleet traffic SHALL NOT continue draining into the DLQ until
  `MaxBytes` is exhausted

#### Scenario: Operator redrives a repaired cohort

- **GIVEN** an authorized operator selects an exact retained error cohort after
  its decoder or schema is repaired
- **WHEN** the bounded redriver republishes a cataloged record
- **THEN** it SHALL use fresh synthetic delivery-lane coordinates through the
  current stream map while preserving the original traffic class, semantic
  digest, body, network scope, output contract, producer provenance,
  authorization, and applicable collection proof
- **AND** it SHALL record the audited attempt/outcome and rely on the ordinary
  semantic ledger for idempotency

#### Scenario: A cataloged DLQ record is eligible for deletion

- **GIVEN** a catalog entry is durably `resolved`, `redriven`, or explicitly
  `waived` by an authorized actor
- **WHEN** its dependent semantic-ledger and audit safe-GC watermarks have closed
- **THEN** the authorized deleter MAY remove that exact physical stream sequence
- **AND** time alone, stream pressure, or an absent catalog entry SHALL NOT delete
  it
