# edge-architecture Delta

## ADDED Requirements

### Requirement: Record stream flow control has application semantics
The edge record RPCs SHALL use bounded bidirectional streaming with cumulative
application dispositions over the finite platform-owned route-profile/class and
recovery spool sequences. Lane identity SHALL NOT be keyed by output contract,
payload kind, or package. Bulk and interactive
lanes SHALL have disjoint physical streams and durable consumers. Every lane
SHALL have an independent RPC, and bulk, interactive, and recovery SHALL use
separately pooled HTTP/2 connections with reserved connection-level windows.
Transport-level write completion or HTTP/2 flow-control progress SHALL NOT be
interpreted as durable acceptance.

#### Scenario: Receiver pressure closes the send window
- **GIVEN** the configured in-flight byte or frame window is full
- **WHEN** additional agent frames are ready
- **THEN** the sender SHALL retain them in its disk spool and stop advancing the
  application window
- **AND** affected producer admission SHALL react before the spool can overwrite
  unacknowledged data

#### Scenario: Cumulative acknowledgement has a gap
- **GIVEN** a later frame obtains PubAck while an earlier sequence has not
- **WHEN** the gateway computes its response
- **THEN** it SHALL acknowledge only the highest contiguous PubAcked sequence
- **AND** the missing sequence SHALL remain eligible for retry

#### Scenario: Bulk publication is blocked
- **GIVEN** a bulk sweep, trace, inventory, plugin, or integration spool
  sequence cannot advance
- **WHEN** interactive results are available on their independently budgeted
  lane
- **THEN** the gateway SHALL continue accepting interactive work within its
  bounded credits and class-specific quota
- **AND** bulk backlog SHALL NOT consume the interactive HTTP/2 connection,
  gateway publisher connection, stream, or durable consumer

#### Scenario: Lane reconnects to a replacement gateway
- **WHEN** an agent opens a new record session
- **THEN** it SHALL declare spool ID, sequence base, first unresolved
  sequence, fresh nonce, and requested credits
- **AND** SHALL ignore dispositions that do not match its active nonce and spool

### Requirement: Gateway disposition evidence retention is bounded and replay-safe
A gateway SHALL NOT evict volatile per-sequence terminal-disposition evidence
unless it has successfully written an ordered cumulative `EdgeDeliveryAckV1`
covering those sequences and the same validated idempotent publication path can
reproduce the terminal disposition and authoritative PubAck after ACK loss,
duplicate replay, or reconnect, without subscribing to stored records or
recovering private gateway state.
Retained gateway disposition evidence SHALL have a documented bound independent
of total lane lifetime. Reporting or evicting gateway evidence SHALL NOT advance
the agent-local reclaim watermark or authorize spool deletion.

#### Scenario: Written cumulative acknowledgement is lost
- **GIVEN** the gateway has written a cumulative acknowledgement and evicted the
  covered volatile disposition evidence
- **WHEN** the agent does not observe that acknowledgement and replays the same
  immutable slot from its first unresolved sequence
- **THEN** the gateway SHALL idempotently repeat the required publication and
  validated PubAck path to reproduce the same terminal disposition
- **AND** SHALL rebuild the contiguous resolved prefix without an ambiguous
  result caused solely by evidence eviction

#### Scenario: Long-lived lane bounds retained evidence
- **GIVEN** a lane continues resolving frames beyond every configured in-flight
  window
- **WHEN** ordered cumulative acknowledgements are successfully written
- **THEN** retained gateway disposition evidence SHALL remain within its
  documented frame-and-byte bound
- **AND** the bound SHALL NOT grow with the total number of frames processed by
  the lane

#### Scenario: Retryable gap applies bounded backpressure
- **GIVEN** an earlier sequence remains retryable or unresolved while later
  publications obtain terminal PubAcks
- **WHEN** the contiguous acknowledgement cannot cover those later outcomes
- **THEN** the gateway SHALL apply lane-local backpressure before retained
  disposition evidence exceeds its documented frame-and-byte bound
- **AND** SHALL NOT cross the gap or discard evidence that the idempotent
  publication and validated PubAck path cannot reproduce
