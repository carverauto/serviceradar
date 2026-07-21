# agent-connectivity Delta

## ADDED Requirements

### Requirement: Edge result capability negotiation is bidirectional
Agents SHALL advertise the edge-record protocol, supported platform payload
families/encodings/compression, durable spool-reader versions, frame bounds, and
output-contract registry epoch/digest in Hello. The gateway SHALL return
result-ingest readiness derived from
the complete installation-local path, including mandatory disjoint bulk and
interactive streams, PubAck publication, supported schemas, and consumers,
rather than its binary version alone. Readiness SHALL require the configured
minimum dual-path agent/gateway version that supports independently
acknowledged bounded legacy frames and v1 frames.

#### Scenario: Agent and installation path support v1
- **GIVEN** an agent satisfies the minimum dual-path version and advertises
  `edge-results:v1`, its spool version, and the required registry epoch
- **WHEN** the connected installation gateway pool has writable
  class-separated authoritative streams and compatible consumers
- **THEN** the gateway SHALL advertise v1 ready
- **AND** explicit config MAY select v1 for a new producer run

#### Scenario: One gateway pool member is not ready
- **GIVEN** an agent may reconnect to any gateway in its installation pool
- **WHEN** a pool member cannot accept and drain v1
- **THEN** fleet/cohort configuration SHALL NOT assume uniform v1 readiness
- **AND** a v1-spooled run SHALL be retried through a compatible gateway,
  not converted to legacy in flight

#### Scenario: Binary is below the dual-path minimum
- **WHEN** an agent or reachable gateway does not satisfy the configured minimum
  dual-path version
- **THEN** no new affected durable producer run SHALL be assigned through that path
- **AND** the system SHALL require upgrade rather than provide an
  unpatched-agent compatibility bridge

#### Scenario: Agent lacks the selected contract or encoder
- **WHEN** configuration requests an output contract/encoding the agent did not
  advertise under the required registry
- **THEN** the agent SHALL reject or defer that new run with an explicit
  capability error
- **AND** SHALL NOT infer a format from config content hash

### Requirement: Output contract and format are sticky per producer run
The output contract and format SHALL remain sticky for each producer run. The
effective patched bounded-legacy or exact v1 output-contract bundle, registry
epoch, encoding, route profile, and traffic class SHALL be selected
before a producer run starts and SHALL remain immutable for that run and every
retry. A shared lane MAY multiplex records from different contracts. Changing
rollout configuration SHALL affect only new runs while pinned backlog drains.

#### Scenario: Rollback occurs with a v1 spool backlog
- **WHEN** rollout config selects patched bounded legacy for new affected runs
- **THEN** the agent SHALL continue opening compatible v1 result lanes until its
  existing v1 spool is resolved
- **AND** no rollback binary lacking that spool reader/sender or historical
  contract registry SHALL replace it

#### Scenario: Connection changes during a run
- **WHEN** an agent reconnects to another ready gateway while a v1 run is
  active
- **THEN** it SHALL reopen each lane with the same spool identity and first
  unresolved sequence
- **AND** the run SHALL remain pinned without dual authoritative emission

#### Scenario: Registry changes during an existing run
- **WHEN** a new registry epoch activates while an old run has spooled records
- **THEN** the old run SHALL drain under its pinned historical bundle and route
- **AND** only new runs SHALL use the new effective grant

### Requirement: Result stream sessions are replay-safe
Each result lane SHALL be replay-safe. The finite platform-owned
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
- **GIVEN** an agent has replaced a result-stream session
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
  original semantic ID/body, fsync the new segment and mapping watermark, and
  only then reclaim that exact old source segment after required recovery
  PubAcks
- **AND** startup SHALL resume idempotently at every copy, fsync, PubAck, and
  delete boundary
- **AND** a recovery PubAck SHALL stop publication retry but SHALL NOT authorize
  local rollover-journal or proof garbage collection
- **AND** terminal recovery state and journal garbage collection SHALL require
  either a locally persisted signed durable `RecoveryResolvedV1` or an
  idempotent recovery-status query confirming consumer-transaction commit for
  the complete manifest
- **AND** SHALL NOT describe the lost sequence as an accepted result

### Requirement: Agent result storage has one hard filesystem budget
The agent SHALL use one crash-safe atomic byte allocator for all result lanes,
raw quarantine, both recovery-journal copies, segment and directory metadata,
rollover copy amplification, and scratch space. Per-lane quotas SHALL be
subordinate to that global limit. A hard minimum-free-space floor SHALL be
unborrowable by ordinary result data and reserved for recovery/control and
terminal evidence.

#### Scenario: Nominal lane quotas exceed available disk
- **GIVEN** every individual lane remains below its configured quota
- **WHEN** their combined reservations plus quarantine, journals, and recovery
  scratch would cross the filesystem limit or minimum-free-space floor
- **THEN** the allocator SHALL refuse new ordinary collection reservations
- **AND** SHALL preserve enough space to durably abort/terminalize work and report
  or recover already-committed spool state
