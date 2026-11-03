# agent-connectivity Delta

## ADDED Requirements

### Requirement: Edge record stream sessions are replay-safe
Each record lane SHALL be replay-safe. The finite platform-owned
route-profile/traffic-class and recovery lanes SHALL open with lane kind,
immutable scheduler-signed traffic
class where applicable, persistent spool identity, sequence base, first
unresolved sequence, fresh session nonce, and requested byte/frame credits.
Bulk and interactive results SHALL use disjoint physical streams and durable
consumers. The agent SHALL accept dispositions only from its active matching
session and SHALL NOT change traffic class during retry, rollover, quarantine,
DLQ handling, or redrive.
Lane identity SHALL NOT be keyed by output contract, payload kind, package,
plugin, or integration.

Each lane SHALL use an independent bidirectional RPC. Bulk, interactive, and
recovery lanes SHALL use separately pooled HTTP/2 transport connections with
independent connection-level windows and pending-byte ceilings; they SHALL NOT
share one connection-level flow-control budget across traffic classes.

#### Scenario: Stale gateway response arrives
- **GIVEN** an agent has replaced a record-stream session
- **WHEN** an ACK/disposition from the previous nonce arrives
- **THEN** the agent SHALL ignore it
- **AND** SHALL reclaim no spool record because of the stale response

#### Scenario: Replacement gateway has no ACK memory
- **WHEN** an agent opens a lane on a replacement gateway
- **THEN** it SHALL replay from its first unresolved sequence
- **AND** stable broker/database idempotency SHALL make gateway-local durable
  state unnecessary

#### Scenario: Bulk transport stops consuming bytes
- **GIVEN** a bulk RPC or its HTTP/2 connection has exhausted its send window
- **WHEN** an interactive or recovery frame is ready
- **THEN** it SHALL use its separately pooled transport connection and
  independently reserved application credits
- **AND** the blocked bulk connection SHALL NOT delay its write or disposition

#### Scenario: Lane rolls over after durable local loss
- **GIVEN** one committed sequence cannot be reconstructed but later records are
  readable
- **WHEN** the agent records a durable rollover journal and bounded loss manifest
- **THEN** it SHALL copy each unresolved readable segment to a fresh lane with
  original semantic ID/body, and fsync the new segment and mapping watermark
- **AND** it SHALL reclaim that exact old source segment ONLY after the
  allocated-sequence COVERAGE PROOF holds for it -- every allocated sequence,
  INCLUDING MARKERLESS ALLOCATED SLOTS, covered by a fully committed,
  sender-visible destination slot with rebound attribution and directory evidence,
  or by a PubAcked frozen loss span WHOSE COVERED SEQUENCES ARE EACH BACKED BY
  DURABLE PER-SEQUENCE LOSS EVIDENCE WHOSE JOURNALED CLASSIFICATION MATCHES THE
  SPAN'S COMPLETE ONEOF BODY (the PubAck alone does not authorize deletion)
  -- funded by the AGGREGATE recovery reserve.
  Destination fsync plus a mapping watermark and recovery PubAcks is NOT
  sufficient: it says nothing about slots that were allocated but never committed,
  and reclaiming over one destroys the only intact evidence they existed
- **AND** startup SHALL resume idempotently at every copy, fsync, PubAck, and
  delete boundary
- **AND** a recovery PubAck SHALL stop publication retry but SHALL NOT authorize
  local rollover-journal or proof garbage collection
- **AND** terminal recovery state and journal garbage collection SHALL require
  either a locally persisted signed durable `RecoveryResolvedV1` or an
  idempotent recovery-status query confirming consumer-transaction commit for
  the complete manifest
- **AND** SHALL NOT describe the lost sequence as an accepted result
