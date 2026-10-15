## ADDED Requirements

### Requirement: Negative acknowledgements of retained streams name the committed chunks
When the agent-gateway answers an agent-retained `StreamStatus` RPC with `received: false`, it SHALL list in `GatewayStatusResponse.committed_chunk_indexes` the `chunk_index` of every chunk whose status reached its durable acceptance boundary, in ascending order. A status whose registered-handler failure was durably recorded counts as committed. The list SHALL be empty when no chunk committed, and it SHALL NOT change the RPC-wide meaning of `received` or the rule that an unacknowledged RPC returns no directives. A sender SHALL treat an empty or absent list as "nothing committed", which is also what a gateway that predates the field sends.

#### Scenario: One chunk of a retained plugin stream does not commit
- **GIVEN** a valid three-chunk retained plugin-result stream
- **WHEN** chunks 0 and 2 commit and chunk 1 misses its acceptance boundary
- **THEN** the agent-gateway SHALL complete the RPC with `received: false`
- **AND** `committed_chunk_indexes` SHALL be `[0, 2]`
- **AND** it SHALL return no directives

#### Scenario: Every chunk commits
- **WHEN** every chunk of a retained plugin-result stream commits
- **THEN** the agent-gateway SHALL complete the RPC with `received: true`
- **AND** the sender SHALL release every status in the stream

## MODIFIED Requirements

### Requirement: Retriable agent-retained delivery failures use negative acknowledgements
For a valid agent-retained RPC, a downstream unavailability, processing timeout, bounded-queue saturation or unavailability, worker failure, or durable-persistence failure SHALL produce `received: false` in an otherwise successful gRPC response. Such a delivery failure SHALL NOT be represented as a gRPC transport error and SHALL NOT invalidate or tear down the shared agent-to-gateway connection. The sender SHALL retain for retry every agent-retained status in the RPC that the response does not name in `committed_chunk_indexes`, in its original order, and SHALL release the statuses it does name. When the response names none, the sender SHALL retain the complete set. Agent-retained processing SHALL tolerate replay when a prior attempt may have committed more than the response reported before returning `received: false`.

#### Scenario: Core is unavailable for a valid agent-retained status
- **GIVEN** an agent sends a valid isolated agent-retained status
- **WHEN** core is unavailable before confirming a durable commit
- **THEN** the agent-gateway SHALL complete the RPC with `received: false`
- **AND** the agent SHALL retain the unacknowledged status for retry
- **AND** the shared connection SHALL remain usable for subsequent status RPCs

#### Scenario: Agent-retained delivery queue cannot accept work
- **GIVEN** an agent sends a valid isolated agent-retained status
- **WHEN** the downstream bounded delivery queue is full, unavailable, or cannot complete the work before the delivery deadline
- **THEN** the agent-gateway SHALL complete the RPC with `received: false`
- **AND** queue admission alone SHALL NOT be reported as durable receipt

#### Scenario: A negative acknowledgement names committed retained plugin chunks
- **GIVEN** a retained plugin-result stream returned `received: false` with `committed_chunk_indexes` naming some of its chunks
- **WHEN** the agent retries
- **THEN** it SHALL resend only the results behind the chunks the response did not name, in their original order
- **AND** it SHALL NOT resend a result whose chunk was named
- **AND** it SHALL NOT add newly produced results to the retried remainder

#### Scenario: A negative acknowledgement names no committed chunk
- **GIVEN** an agent-retained stream returned `received: false` with no `committed_chunk_indexes`, either because nothing committed or because the gateway predates the field
- **WHEN** the agent retries
- **THEN** it SHALL resend the complete retained stream
- **AND** the agent-retained pipeline SHALL converge on the same durable result without creating duplicate logical records
- **AND** the agent SHALL release the retained set only after a later `received: true`
