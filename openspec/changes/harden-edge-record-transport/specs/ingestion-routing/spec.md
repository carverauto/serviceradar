# ingestion-routing Delta

## ADDED Requirements

### Requirement: Route-map placement is resolved against an immutable generation
Runtime integration SHALL resolve the provenance-carried `route_map_version` against an
active or retained immutable route-map generation and SHALL verify that the authenticated
publisher class, subject, physical stream, route profile, and traffic class agree with that
generation. The `route_map_version` is diagnostic placement metadata that the pure codec only
requires to be nonzero, decodes, and exposes; there is NO separate `Sr-Edge-Route-Map-Version`
header. A retained generation SHALL remain valid while its accepted stream drains.

#### Scenario: Route-map generation is unknown or unavailable
- **WHEN** a delivery's `route_map_version` resolves to no known or currently available
  route-map generation
- **THEN** readiness SHALL fail WITHOUT resolving the source delivery (no ACK, no NAK)
- **AND** the source delivery SHALL remain eligible for idempotent redelivery once the
  generation becomes resolvable

#### Scenario: Authenticated placement disagrees with the resolved generation
- **GIVEN** a `route_map_version` that resolves to a known route-map generation
- **WHEN** the authenticated publisher class, subject, physical stream, route profile,
  or traffic class does not agree with that generation
- **THEN** EventWriter SHALL fail closed and classify the delivery as a
  transport-integrity failure, never authoritatively projecting it

### Requirement: Edge record ingestion is bounded at the transport and the gateway
The transport and the gateway SHALL enforce the frozen record and frame bounds in operation, before buffering and before decompression.

The field sets, the hard byte bound, and the `record_sha256` rule are frozen by the
`freeze-edge-record-v1-abi` change. This requirement owns their enforcement and the
surrounding pipeline: trusted projected cost, route, traffic class, and provenance
SHALL be derived by the agent sink from the approved contract/grant rather than
accepted from a producer, and the agent sink SHALL encode the complete
producer-neutral semantic record bytes once.

Every `EdgeDeliveryFrameV1` SHALL carry the exact `EdgeRecordV1` bytes and digest
plus persistent spool identity, monotonic lane sequence, and other bounded edge-
delivery/session coordinates. Delivery coordinates SHALL NOT be part of the
canonical semantic record or its digest. Recovery MAY wrap the same record bytes
in a new fenced delivery frame without changing semantic identity. Gateway
receipt, physical stream/sequence, and stream-map placement are broker placement
metadata and SHALL NOT be injected into or rewrite `EdgeRecordV1`.



#### Scenario: Exact binary envelope is persisted

- **GIVEN** the gateway validates a supported agent-spooled delivery frame
- **WHEN** it durably publishes the contained record
- **THEN** the JetStream body SHALL be byte-for-byte identical to
  `EdgeDeliveryFrameV1.record_bytes` and the common-spooled `EdgeRecordV1` bytes
- **AND** EventWriter SHALL recover contract, provenance, authorization, cost,
  semantic identity, and canonical content by decoding that binary body rather
  than an `Sr-Edge-*` header set
- **AND** delivery-only reauthorization or recovery MAY replace delivery-frame
  coordinates around those exact bytes but SHALL NOT rewrite the record,
  semantic digest, traffic class, or original collection proof

#### Scenario: Batch builder reaches its byte target

- **WHEN** adding another observation would move a frame past its byte target
- **THEN** the agent SHALL flush the current independently decodable frame
- **AND** item-count guards SHALL remain secondary to actual encoded size

#### Scenario: Unexpected record cannot fit

- **WHEN** one record violates the configured field or frame bounds
- **THEN** the producer SHALL quarantine it with a structured operator-visible
  error
- **AND** it SHALL NOT retry the same impossible frame indefinitely

#### Scenario: Producer understates projected cost

- **WHEN** a producer submission supplies a route, traffic class, provenance, or
  projected database cost that differs from its effective grant
- **THEN** the agent sink SHALL ignore and replace non-authoritative metadata or
  reject the submission before spool acceptance
- **AND** the consumer SHALL verify the platform-stamped cost-model version and
  decoded worst-case cost before reserving destination capacity

The gateway SHALL validate the delivery frame and enough of the fixed semantic
record to authorize and route it, then JetStream-publish the exact `record_bytes`
unchanged. Before any protobuf unmarshal, the gateway and EventWriter SHALL reject
a frame/record whose raw length exceeds its frozen hard byte bound AND SHALL verify `record_sha256` over `record_bytes`. On the STREAMING
gRPC ingest path this bound SHALL be enforced at the TRANSPORT, BEFORE the body is
buffered and BEFORE any decompression: the gateway SHALL reject a declared gRPC message
length exceeding the client-message bound BEFORE accumulating any chunk toward it (never
buffering to an attacker-declared 32-bit length), and SHALL DISABLE gRPC message
compression on the edge-ingest lane: a message whose gRPC compressed-flag is set SHALL be
REJECTED immediately (there is no bounded-decompression fallback, because decompression
occurs before the codec/decode sees the bytes and a unary body-size limit does not cover
the stream). Each component SHALL then
decode and hash the record at most once and perform at most one streaming
decompression bounded by an independent hard output/expansion limit, never trusting
the declared `uncompressed_size` as an allocation authority. Broker
headers SHALL be transport-minimal, limited to protocol fields required for
deduplication, expected-stream fencing, and bounded tracing; they SHALL NOT
duplicate semantic metadata or act as identity, contract, authorization, cost,
or routing authority. EventWriter SHALL decode and validate the complete binary
`EdgeRecordV1` from the JetStream body. Broker publication identity SHALL bind trusted
network scope/agent, spool ID/sequence, the exact-record checksum
`record_sha256`, and the semantic digest, so that two different outer encodings in
one slot receive DIFFERENT `Nats-Msg-Id` values and both reach EventWriter for the
physical-slot integrity check rather than one being silently suppressed by broker
deduplication. A legitimate same-lane retry reuses the exact record bytes and
therefore the same `record_sha256`, keeping lost-ACK deduplication intact. The `EdgeRecordV1` target encoded size SHALL be 256 KiB; its hard bound, the
delivery-frame bound, and the client-message bound are the frozen `MaxRecordBytes`,
`MaxFrameBytes`, and `MaxClientMessageBytes` values owned by the edge record v1
wire ABI, and SHALL NOT be restated as literals here.
