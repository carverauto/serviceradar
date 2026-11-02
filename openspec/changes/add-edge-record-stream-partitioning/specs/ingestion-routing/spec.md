# ingestion-routing Delta

## ADDED Requirements

### Requirement: Traffic-class routing is immutable and physically disjoint
Every result SHALL carry exactly one control-plane-attested `traffic_class` of
`bulk` or `interactive`. All approved durable output contracts SHALL publish to
the fixed installation-local `telemetry.edge-record.v1.bulk.pNN` or
`telemetry.edge-record.v1.interactive.pNN` subjects for the initial
`durable-records-v1` route profile. The signed grant/capability, edge frame, semantic
digest, subject, expected-stream publish fence, and stream-map entry SHALL agree
on the class; a broker header SHALL NOT override the decoded binary envelope.
Bulk and interactive traffic SHALL use disjoint file-backed physical streams
and persistence durables, and replay, rollover, recovery, derived work, DLQ,
quarantine reclassification, and redrive SHALL preserve the original class.
Package, payload-kind, and output-contract count SHALL NOT create new lane,
subject, stream, consumer, connection, process, or RAFT-group cardinality.

#### Scenario: A producer attempts class promotion
- **GIVEN** a bulk assignment has a valid signed collection capability
- **WHEN** its frame, subject, stream-map entry, replay, or redrive claims the
  interactive class
- **THEN** the gateway or consumer SHALL reject the mismatch before consuming
  class-reserved capacity or producing side effects
- **AND** the event SHALL NOT consume the interactive stream, durable, claim
  queue, or database-credit floor

#### Scenario: Bulk physical stream is catching up
- **GIVEN** the bulk stream and durable contain a large retained backlog
- **WHEN** an admitted interactive result arrives
- **THEN** its disjoint interactive physical stream and durable SHALL remain
  reachable within the configured latency reservation
- **AND** overlapping filtered durables or subjects that give one message more
  than one authoritative ownership path SHALL fail readiness

#### Scenario: Stream-map version changes
- **WHEN** a logical partition moves to a new physical stream
- **THEN** admission SHALL stop behind a publish barrier until old gateway
  leases are revoked or expired and exactly one writable subject authority is
  active
- **AND** the sealed old durable SHALL remain restartable and drain through its
  AckWait, redelivery, repair, and rollback watermark
- **AND** every immutable historical map version, publisher fence, subject
  authority, and consumer configuration SHALL be retained until that watermark

