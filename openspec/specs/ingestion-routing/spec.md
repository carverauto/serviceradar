# ingestion-routing Specification

## Purpose
TBD - created by archiving change add-tenant-ingestion-routing. Update Purpose after archive.
## Requirements
### Requirement: Tenant-Scoped Ingestion Workers
The system SHALL route sync result chunks to a tenant-scoped ingestion worker registered in the ERTS cluster so that ingestion ownership is explicit and redistributable.

#### Scenario: Chunk routed to tenant worker
- **WHEN** a sync results chunk arrives for tenant A
- **THEN** the agent-gateway routes the chunk to tenant A's ingestion worker
- **AND** the worker processes the chunk without blocking other tenants

#### Scenario: Worker redistribution on node failure
- **GIVEN** tenant A's ingestion worker is running on node X
- **WHEN** node X disconnects from the cluster
- **THEN** Horde reassigns the worker to another node
- **AND** subsequent chunks are routed to the new owner

### Requirement: Per-Tenant Backpressure
The system SHALL bound the number of in-flight chunks per tenant and queue or defer excess chunks to protect shared resources.

#### Scenario: Tenant exceeds concurrency limit
- **GIVEN** tenant A has reached the in-flight chunk limit
- **WHEN** another sync chunk arrives for tenant A
- **THEN** the system queues or defers the chunk
- **AND** emits metrics/logs for queue depth and delay

### Requirement: Automatic Worker Lifecycle
The system SHALL start tenant ingestion workers automatically without requiring additional Kubernetes workloads.

#### Scenario: First sync chunk for new tenant
- **WHEN** the first sync results chunk arrives for a newly onboarded tenant
- **THEN** the core cluster starts the tenant worker automatically
- **AND** no manual k8s changes are required

#### Scenario: Horizontal scale adds capacity
- **GIVEN** multiple core-elx pods are running
- **WHEN** a new pod joins the cluster
- **THEN** ingestion workers MAY be redistributed to balance load
- **AND** ingestion continues without service interruption

### Requirement: Broker-Free Large Payload Handling
The system SHALL continue to process large sync results via streaming gRPC chunking and MUST NOT require NATS for sync ingestion.

#### Scenario: Large sync payload delivered via chunks
- **WHEN** a sync results payload exceeds single-message limits
- **THEN** it is delivered as multiple gRPC chunks
- **AND** ingestion proceeds through tenant workers without NATS involvement

### Requirement: Edge records and delivery frames are byte-bounded and versioned
Every `EdgeRecordV1` and `EdgeDeliveryFrameV1` SHALL declare a FROZEN field set, and SHALL be bounded by a hard byte limit checked before any decode.

Every `EdgeRecordV1` SHALL declare its platform payload family, exact
output-contract ID/version/bundle digest and registry epoch, authenticated
producer/package/assignment/run context, platform route profile,
compression, encoded and uncompressed sizes, checksum, stable event ID, projected
database-row cost, projected database-write bytes, and cost-model version. It SHALL
also declare exactly one authoritative `network_scope_id`, immutable signed
`traffic_class`, authorization kind/context, and any source/run/execution/shard/
epoch/range ID/digest covered by its signed capability. Its semantic digest SHALL
bind network scope, authenticated agent, traffic class, output/schema/cost
contract, authorization, producer/run, execution, assignment, range, observation
identity, and canonical content.

The hard byte bounds are FROZEN, and each is NAMED so downstream references have an
exact anchor rather than relying on prose correspondence: `MaxRecordBytes` = 512 KiB
bounds one `EdgeRecordV1`; `MaxDeliveryEnvelopeBytes` = 16 KiB bounds the
delivery-frame envelope; `MaxFrameBytes` = `MaxRecordBytes + MaxDeliveryEnvelopeBytes`
= 528 KiB bounds one `EdgeDeliveryFrameV1`; and `MaxClientMessageBytes` =
`MaxFrameBytes + 8` bounds one `EdgeRecordClientMessage`, covering the oneof tag and
its length prefix. The `+ 8` is CONSERVATIVE HEADROOM, not an exact derivation: the oneof framing at
the maximum frame size needs 1 tag byte plus a 3-byte varint length. What is
load-bearing is that the client message has its OWN bound; a receiver bounding the
frame but not the enclosing message has an unbounded outer envelope.

The record bound and the frame bound are DIFFERENT bounds. Naming 512 KiB as the
FRAME limit -- as earlier revisions of the downstream capabilities did -- is an
incompatible bound, not a rounding difference: it silently rejects a maximum-size
record carrying any delivery envelope at all.

WHO derives the trusted cost, route, traffic class, and provenance; how a transport
enforces the bound before buffering and before decompression; and how the gateway
validates, batches, publishes, or quarantines are DOWNSTREAM runtime behaviour over
this contract.

#### Scenario: Compressed size declaration lies

- **WHEN** streaming decompression exceeds the independent output or expansion
  limit or does not equal the declared size
- **THEN** the consumer SHALL stop before unbounded allocation and classify the
  event as poison
- **AND** unsupported dictionaries, trailing frames, and excessive protobuf
  recursion SHALL be rejected

#### Scenario: A record exceeds its hard bound
- **WHEN** a frame or record's raw length exceeds its declared hard byte bound
- **THEN** it SHALL be rejected BEFORE any protobuf unmarshal

#### Scenario: Delivery coordinates are kept out of semantic identity
- **WHEN** recovery rewraps the same record bytes in a new delivery frame
- **THEN** the semantic identity and digest SHALL be unchanged
- **AND** broker placement metadata SHALL NOT be written into `EdgeRecordV1`

### Requirement: A refusal's classification decides retryability and is frozen
A component that refuses an edge record SHALL classify the refusal as exactly one of `poison`,
`systemic`, or `not_ready`, and that classification SHALL determine the delivery's disposition:

| classification | disposition |
|---|---|
| `poison` | PERMANENTLY resolves the delivery. The input is bad and no retry can succeed. |
| `systemic` | PAUSES. The input may be valid and this deployment is at fault. |
| `not_ready` | Leaves the delivery UNRESOLVED for a later attempt. |

THE CLASSIFICATION IS PART OF THE CONTRACT, NOT A LOCAL LOGGING CHOICE. Whether bytes are
refused is one question and what the refusal is CALLED is another, and only the second decides
whether the same bytes are retried forever. Two runtimes can agree exactly on which inputs they
reject and still diverge here, and no accept/refuse corpus can observe it, because neither
`systemic` nor `not_ready` is a refusal at all.

MALFORMED WIRE BYTES SHALL BE CLASSIFIED `poison`. A runtime whose decoder is more lenient than
the frozen wire rules SHALL run a STRUCTURAL PREFLIGHT it owns before that decoder, so malformed
input is refused by this contract's rules rather than by whichever exception a third-party
decoder happens to raise.

AN AMBIGUOUS FAILURE -- one a malformed input and a deployment defect can BOTH produce -- SHALL
be classified `systemic`, never `poison`. A deployment defect must not permanently destroy valid
data. That default is deliberately the retryable one, so the ambiguous path SHALL be kept EMPTY
by the preflight rather than merely tolerated, and its emptiness SHALL be MEASURED over
malformed inputs rather than argued from the design.

AN UNRECOGNISED FAILURE SHALL be classified `systemic`. Failing closed here means failing toward
retry, not toward destruction: an unfamiliar fault is more likely a defect in the deployment
than proof the input is bad.

#### Scenario: Malformed bytes are refused permanently
- **WHEN** an input fails the structural preflight or the decoder rejects it as malformed
- **THEN** the refusal SHALL be classified `poison`
- **AND** the delivery SHALL be permanently resolved rather than retried

#### Scenario: An ambiguous failure pauses instead of destroying
- **WHEN** a failure could have been caused either by malformed input or by a codegen,
  metadata, or configuration defect in the deployment
- **THEN** it SHALL be classified `systemic`
- **AND** it SHALL NOT permanently resolve the delivery

#### Scenario: The ambiguous path is measured empty
- **WHEN** malformed inputs are generated against a valid record and driven through the
  preflight and decoder
- **THEN** the count reaching the ambiguous classification SHALL be reported
- **AND** an input surviving the preflight to reach it SHALL be treated as a defect in the
  preflight, because at a known delivery slot it would be retried forever

