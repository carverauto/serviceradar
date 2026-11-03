# cnpg Delta

## ADDED Requirements

### Requirement: Edge durable record projection is idempotent
CNPG SHALL store an ingest ledger and contract-specific domain uniqueness
constraints sufficient to make sweep, execution, OCSF, MTR trace/hop,
inventory, and metric/event projection idempotent
under retries beyond the JetStream duplicate window. The ledger SHALL be keyed
ONLY by (`network_scope_id`, semantic event ID) -- a metadata retention bucket
deterministically derived from the semantic event ID MAY join the physical SQL
partitioning key. It SHALL STORE authenticated agent, exact output-contract
bundle, authenticated producer/package/assignment/run context, immutable
`traffic_class`, immutable `semantic_envelope_sha256` (the sole conflict/replay
comparison value), encoded and projected-write byte counts, cost-model version,
expected/projected record counts, and commit state as immutable COMPARISON
VALUES that a conflicting record is checked against -- never as lookup-key
components -- and without storing a duplicate payload body. `record_sha256` is
NOT a ledger conflict-comparison value; it lives on the DELIVERY-SLOT binding as
the physical-slot conflict comparison. The SQL delivery-slot uniqueness binding,
keyed by the frozen `edge_slot` tuple, SHALL be created for EVERY gateway-accepted
delivery -- primary, audit, replay, poison, and conflict -- BEFORE its source ACK,
recording `record_sha256` as the compared value; for poison and conflict deliveries
the binding is audit-only and drives NO domain projection. A DLQ-ACKed poison or
conflict record therefore still leaves an immutable slot binding, so a later frame
reusing the same `edge_slot` with a different `record_sha256` is detected as a
transport-integrity conflict rather than silently accepted. An IDENTICAL SQL
service-slot uniqueness binding, keyed by the frozen `service_slot` tuple
(`network_scope_id`, `authenticated_service_id`, `publication_lane_id`,
`publication_sequence`), SHALL be created for EVERY accepted governed-service
delivery -- alongside `edge_slot` and following the same rules -- BEFORE its source
ACK, recording `record_sha256` as the compared value, so a service-ingress frame
reusing one `service_slot` with a different `record_sha256` is likewise detected as
a transport-integrity conflict rather than silently accepted. On an
`EVENT_ID_CONFLICT`, the conflict
DLQ path SHALL retain the first-accepted `record_sha256` as MANDATORY audit-only
forensic provenance -- not optional -- and that retained `record_sha256` is
EXCLUDED from replay/conflict comparison; only `semantic_envelope_sha256`
decides ledger replay versus conflict. Every
address-derived domain key and deterministic derived-event key SHALL begin with
the authoritative `network_scope_id`. Every v1 semantic event ID SHALL be
RFC 9562 UUIDv7; the metadata bucket / partition selection and the
collection/execution-timing agreement SHALL be validated against the
authoritative body observation/event time (with the UUIDv7 timestamp checked
for consistency, not trusted in isolation) so one ID cannot move between ledger
partitions.

#### Scenario: Committed event is replayed
- **WHEN** the same event is received again for the same (`network_scope_id`,
  semantic event ID) ledger key (in its event-ID-derived metadata bucket) with a
  matching stored `semantic_envelope_sha256` (and matching stored agent and
  contract comparison values)
- **THEN** the projector SHALL detect its committed ledger entry without
  repeating domain side effects
- **AND** return success so the JetStream delivery can be acknowledged

#### Scenario: Event ID has conflicting content
- **WHEN** the same namespaced semantic event ID is received with a different
  immutable `semantic_envelope_sha256`
- **THEN** the transaction SHALL reject it as a protocol integrity error
- **AND** SHALL NOT overwrite or merge the committed domain rows

#### Scenario: Projector crashes before commit
- **WHEN** a database transaction fails or the process exits before commit
- **THEN** neither the ledger commit nor partial domain side effects SHALL be
  visible
- **AND** a redelivery SHALL safely retry the complete bounded transaction

#### Scenario: Two events claim one sweep batch sequence
- **GIVEN** one network-scope/execution/shard/assignment-epoch/batch-sequence
  slot is already bound to an event ID, `semantic_envelope_sha256`, traffic
  class, counts, and projected rows
- **WHEN** another event claims that slot with any different binding
- **THEN** the projector SHALL retain the first authenticated committed binding,
  classify the later claim as poison, and SHALL NOT overwrite or merge it
- **AND** the attempt SHALL become `integrity_failed` and its range SHALL be
  retried under a new fenced epoch before authoritative reconciliation completes

#### Scenario: One delivery slot is reused for different semantics
- **GIVEN** a delivery slot whose SQL uniqueness is keyed by the frozen
  `edge_slot` tuple (`network_scope_id`, `authenticated_agent_id`, `spool_id`,
  `sequence`) -- with the partition bucket derived from that tuple,
  NOT part of the uniqueness key -- is bound to one event ID and semantic digest
- **WHEN** a frame claims that slot with a different event ID or semantic digest
- **THEN** the projector SHALL classify the later claim as poison before domain
  side effects
- **AND** the original delivery-slot binding SHALL remain immutable

#### Scenario: One service slot is reused for different bytes
- **GIVEN** a governed-service delivery whose SQL uniqueness is keyed by the frozen
  `service_slot` tuple (`network_scope_id`, `authenticated_service_id`,
  `publication_lane_id`, `publication_sequence`) is bound to one `record_sha256`
  BEFORE its source ACK
- **WHEN** a later service-ingress frame claims that `service_slot` with a different
  `record_sha256`
- **THEN** the projector SHALL detect the transport-integrity conflict rather than
  silently accept it
- **AND** the original `service_slot` binding SHALL remain immutable

#### Scenario: Poison or conflict delivery still binds its slot
- **GIVEN** a gateway-accepted delivery is classified as poison or as an
  `EVENT_ID_CONFLICT` and is destined for a DLQ ACK
- **WHEN** the projector resolves its disposition
- **THEN** an immutable `edge_slot`-keyed binding recording `record_sha256` SHALL
  be created BEFORE the source ACK as an audit-only binding that drives no domain
  projection
- **AND** a later frame reusing the same `edge_slot` with a different
  `record_sha256` SHALL be detected as a transport-integrity conflict rather than
  silently accepted

#### Scenario: Recovery republishes unchanged semantic data
- **GIVEN** spool recovery assigns an unchanged event a new fenced delivery-only spool ID or sequence
- **WHEN** the recovered delivery reaches the projector with its original
  semantic event ID, digest, traffic class, collection proof, and scope
- **THEN** a new delivery-slot binding MAY be created for the new coordinates
- **AND** the semantic ledger SHALL deduplicate the event while authoritative
  attempt fencing still governs every state-changing effect

#### Scenario: Two terminal events claim one agent terminal slot
- **GIVEN** an agent terminal slot keyed by network scope, execution, shard,
  and assignment epoch already binds one terminal kind, event, closed batch
  interval, counts, outcomes, and the versioned MTR COMPLETION digest (there is no
  MTR range root: `range_root_sha256` is RETIRED, tag 20 reserved)
- **WHEN** a conflicting terminal binding or a data batch outside that closed
  interval is projected in any arrival order
- **THEN** the first authenticated terminal binding SHALL remain immutable
- **AND** the attempt SHALL become `integrity_failed`, be excluded from
  authoritative reconciliation, and have its range repaired under a new fenced
  epoch
- **AND** scheduler-authored lost, expired, or superseded state SHALL occupy a
  separate authoritative assignment-state slot rather than agent evidence
