# edge-producer-data-plane Delta

## ADDED Requirements

### Requirement: Governed service ingress is operated by the service publisher
The governed service publisher, not the gateway or EventWriter, SHALL own publication-slot durability, and the control plane SHALL isolate publisher credentials per service.

The `service_slot` tuple, its validity rules, the fresh-only scope, and the three
service transport transcripts are frozen by the edge record v1 wire ABI change.
This requirement owns their operation.

The publisher SHALL ALLOCATE `publication_lane_id` ONCE, durably, before the lane's
first publication, and SHALL keep it stable for that lane's life. A retry, timeout,
or restart of a not-yet-acknowledged publication SHALL REUSE the same
`(publication_lane_id, publication_sequence)`, so a lost-ACK redelivery presents the
exact same `service_slot` and `record_sha256`. The shape and validity of those two
fields are frozen upstream; this requirement owns WHEN they are allocated, reused,
and journaled.

The governed service publisher (or its transactional journal/outbox) -- NOT the gateway or
EventWriter -- SHALL OWN publication-slot durability. For EACH record it SHALL, BEFORE publishing,
ATOMICALLY ALLOCATE the NEXT `publication_sequence` and JOURNAL LOCALLY the `service_slot`, the
exact pending record bytes, and the immutable route/header state. Sequence allocation is NOT gated
on acknowledgement: the publisher MAY have multiple outstanding un-acknowledged sequences
(pipelined), and a validated JetStream PubAck only RESOLVES/RECLAIMS its journaled slot -- it is
never a precondition for allocating the next sequence. A retry/timeout/restart of an
un-acknowledged publication SHALL republish the SAME journaled bytes on the SAME
`(publication_lane_id, publication_sequence)`, so a lost-ACK redelivery deduplicates.
`publication_sequence` SHALL NEVER wrap: on approaching its maximum the publisher SHALL SEAL the
current lane and DRAIN its outstanding journaled work while allocating NEW work on a fresh UUIDv7
`publication_lane_id` starting `publication_sequence` at 1.

Provenance trust for both the agent path and the service-ingress path SHALL be
per-class publisher-subject isolation, NOT a global "only the gateway" rule: ONLY
the authenticated gateway MAY publish to the durable edge-record subject, and ONLY
an authorized governed service MAY publish to its own service-ingress subject, each
over its own isolated publisher credential. A governed service publishes its own
service-stamped provenance to its service-ingress subject; the agent path publishes
gateway-stamped provenance to the edge-record subject.

The control plane SHALL maintain an immutable governed mapping from each
`authenticated_service_id` to exactly one service-ingress subject and publisher
credential. A governed service MAY publish ONLY to its mapped subject over its mapped
credential, and EventWriter SHALL derive the `authenticated_service_id` from the
publish subject and authenticated publisher credential, NEVER from caller-supplied
body or header text. A publish outside a service's mapped subject/credential SHALL be
rejected before projection.

The service-ingress path SHALL STAMP the service variants of the three transport
transcripts -- the `Nats-Msg-Id`, `Sr-Edge-Delivery-Id`, and
`Sr-Edge-Transport-Provenance` service grammars frozen in Appendix A of the edge
record v1 wire ABI change -- computing them over this publication's `service_slot`
rather than agent spool coordinates. Their domain tags, field order, slot-kind
discriminant, and delivery-proof presence rule are NOT restated here. Because
governed publishers emit FRESH records only, the publisher SHALL stamp no
`delivery_proof_digest`, and a receiver SHALL NOT treat its absence as poison.

Service-ingress DELIVERY grants -- renewal, rollover, or late-drain of a service
record -- are OUT OF SCOPE for v1. Governed service publishers SHALL emit FRESH
records only, and their transport provenance SHALL carry no `delivery_proof_digest`.
Late-delivery or recovery of a service-ingress record SHALL require a future version.

A transactional outbox MAY be used only when
the record's system of record is the same operational transaction; metrics and
telemetry SHALL remain JetStream-first.

#### Scenario: Cluster-local telemetry producer publishes a metric
- **WHEN** a cluster service emits persistent telemetry
- **THEN** its service-attested publisher SHALL place the authoritative record in
  JetStream before EventWriter projection
- **AND** it SHALL NOT use an operational database outbox as a database-first
  telemetry path or impersonate an edge agent

#### Scenario: A governed service claims another service identity
- **GIVEN** the control plane maps an `authenticated_service_id` to exactly one
  service-ingress subject and publisher credential
- **WHEN** a caller presents body or header text claiming a different
  `authenticated_service_id` than its authenticated publisher subject/credential
  resolves to
- **THEN** EventWriter SHALL compare, BYTE-FOR-BYTE, the authenticated publisher
  subject/credential identity, the `Sr-Edge-Transport-Provenance` principal, the
  publication-ID principal committed in `Nats-Msg-Id` / `Sr-Edge-Delivery-Id`, and the
  record principal (`producer_context.origin_principal_id`), and SHALL fail closed on ANY
  disagreement -- it MUST NOT silently derive from, override, or ignore a mismatched claim
- **AND** a publish outside the service's mapped subject/credential SHALL be rejected
  before projection

#### Scenario: A service-ingress producer attempts a late delivery
- **GIVEN** service-ingress delivery grants are out of scope for v1 and governed
  services emit fresh records only
- **WHEN** a governed service publisher attempts a renewal, rollover, or late-drain of
  a service record carrying a `delivery_proof_digest`
- **THEN** the deployment SHALL reject it because service-ingress late-delivery
  requires a future version
- **AND** a fresh service record whose provenance carries no `delivery_proof_digest`
  SHALL remain valid

