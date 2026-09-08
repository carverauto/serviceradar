## ADDED Requirements

### Requirement: Agent-retained delivery acknowledgements are truthful and RPC-wide
The agent-gateway SHALL interpret `GatewayStatusResponse.received` as an acknowledgement for the entire RPC payload. For `PushStatus`, the value SHALL cover every service status in the request. For `StreamStatus`, the value SHALL cover every service status in every accepted chunk in the client stream. For an agent-retained delivery, the gateway SHALL return `received: true` only when every status has reached its confirmed durable downstream acceptance boundary; admission to a queue or volatile buffer SHALL NOT satisfy it.

The agent-retained delivery sources governed by this contract SHALL be exactly `flow-attribution` and `plugin-result` from an agent that negotiated the `plugin-result-retained:v1` capability. A `plugin-result` from an agent without that capability MAY continue to use the existing best-effort delivery contract. `otlp-relay` is not an agent-retained source under this requirement and SHALL retain its existing hard-gRPC-error contract because its edge add-on owns a durable retry spool.

#### Scenario: Every agent-retained status commits
- **GIVEN** a valid isolated `flow-attribution` request or a valid homogeneous retained `plugin-result` stream
- **WHEN** every submitted status is durably committed downstream
- **THEN** the agent-gateway SHALL complete the RPC with `received: true`

#### Scenario: Best-effort status is admitted to its configured buffer
- **GIVEN** a valid request containing only best-effort statuses
- **WHEN** forwarding fails and every status is successfully admitted to the configured best-effort buffer
- **THEN** the agent-gateway MAY complete the RPC with `received: true`
- **AND** that acknowledgement SHALL represent best-effort buffer acceptance rather than durable downstream commit

#### Scenario: One agent-retained status does not reach its acceptance boundary
- **GIVEN** a syntactically valid agent-retained status RPC
- **WHEN** any submitted agent-retained status does not reach its durable acceptance boundary
- **THEN** the agent-gateway SHALL complete the RPC with `received: false`
- **AND** it SHALL NOT report partial acceptance as `received: true`
- **AND** it SHALL return no directives from the unacknowledged RPC

### Requirement: Agent-retained status payloads are isolated and homogeneous
A `PushStatus` request containing an agent-retained status SHALL contain exactly one service status. Each `StreamStatus` chunk containing an agent-retained status SHALL contain exactly one service status, and every non-empty chunk in that stream SHALL carry the same agent-retained source. A flow-attribution stream SHALL contain exactly one non-empty chunk; a retained-plugin stream MAY contain up to the existing ten-chunk producer limit. An agent-retained request or stream SHALL NOT mix agent-retained and best-effort statuses or mix `flow-attribution` with retained `plugin-result` statuses. The gateway SHALL retain each agent-retained stream only within the existing bounded chunk/window limits, validate the complete stream before forwarding any service, and reject violations as invalid protocol payloads rather than attempting partial delivery. Valid retained-plugin streams SHALL be forwarded with a fixed concurrency limit of two, matching the corresponding core admission lane for this change.

#### Scenario: One flow-attribution status is isolated
- **WHEN** an agent sends one `flow-attribution` service status in a `PushStatus` request or `StreamStatus` chunk
- **THEN** the gateway SHALL accept the payload for agent-retained delivery
- **AND** no best-effort status SHALL share that request or chunk

#### Scenario: Flow attribution is split across stream chunks
- **WHEN** a `flow-attribution` `StreamStatus` RPC contains more than one non-empty chunk
- **THEN** the agent-gateway SHALL terminate that RPC with a non-OK invalid-payload status
- **AND** it SHALL NOT forward or acknowledge a partial flow-attribution stream

#### Scenario: Retained plugin results span homogeneous chunks
- **GIVEN** an agent negotiated `plugin-result-retained:v1`
- **WHEN** it sends multiple `StreamStatus` chunks containing retained plugin results
- **THEN** each chunk SHALL contain exactly one `plugin-result` service status
- **AND** every non-empty chunk in the RPC SHALL use the `plugin-result` source
- **AND** the final `received` value SHALL acknowledge the whole stream

#### Scenario: Agent-retained source is mixed with another status
- **WHEN** a `PushStatus` request or `StreamStatus` chunk combines an agent-retained status with another service status
- **THEN** the agent-gateway SHALL terminate that RPC with a non-OK invalid-payload status
- **AND** it SHALL NOT forward, buffer, or acknowledge the mixed payload

#### Scenario: Agent-retained source changes within a stream
- **GIVEN** a `StreamStatus` RPC has begun with an agent-retained source
- **WHEN** a later non-empty chunk carries a different source
- **THEN** the agent-gateway SHALL terminate that RPC with a non-OK invalid-payload status
- **AND** it SHALL NOT forward any service from the invalid agent-retained stream
- **AND** it SHALL NOT translate the protocol violation into `received: false`

#### Scenario: Homogeneous retained-plugin stream uses bounded parallelism
- **GIVEN** a valid retained-plugin stream contains multiple ordered chunks
- **WHEN** the gateway forwards the validated stream to core
- **THEN** it SHALL process no more than two statuses concurrently, matching the retained-plugin lane's fixed worker count
- **AND** the sender deadline SHALL be at least `max(30s, ceil(chunk_count / 2) * 30s + 15s)`
- **AND** it SHALL preserve one RPC-wide acknowledgement for the complete ordered set
- **AND** if every status commits, it SHALL combine any directives in original chunk order
- **AND** if any status remains uncommitted, it SHALL return no directives

### Requirement: Retriable agent-retained delivery failures use negative acknowledgements
For a valid agent-retained RPC, a downstream unavailability, processing timeout, bounded-queue saturation or unavailability, worker failure, or durable-persistence failure SHALL produce `received: false` in an otherwise successful gRPC response. Such a delivery failure SHALL NOT be represented as a gRPC transport error and SHALL NOT invalidate or tear down the shared agent-to-gateway connection. The sender SHALL retain the complete unacknowledged agent-retained set for retry, and agent-retained processing SHALL tolerate replay when a prior attempt may have committed only a prefix before returning `received: false`.

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

#### Scenario: A retried stream includes a previously committed prefix
- **GIVEN** an agent-retained stream returned `received: false` after a prefix may have committed
- **WHEN** the agent retries the complete retained stream
- **THEN** the agent-retained pipeline SHALL converge on the same durable result without creating duplicate logical records
- **AND** the agent SHALL release the retained set only after a later `received: true`

### Requirement: Retained Plugin Result Admission Is Bounded Isolated And Commit-Confirmed
Core SHALL execute capability-retained `plugin-result` ingestion through a dedicated supervised admission lane before expensive database or registered-handler work. The lane MUST be independent of flow-attribution admission, retain the original synchronous caller reference, and reply only after both the raw result and its terminal handler outcome have been durably recorded. A terminal handler outcome SHALL be either successful completion or a durably persisted handler failure. It MUST bound concurrency, total admitted item count, total retained encoded payload bytes, per-agent admitted items, queue wait, and worker runtime; item and byte totals SHALL include queued and in-flight work. This change SHALL use exactly two workers, 32 total admitted items, 64 MiB of total retained payload, eight admitted items per agent, a two-second maximum queue wait, and a 20-second worker timeout. Deployments MAY configure different positive item, byte, per-agent, queue-wait, and worker-timeout bounds, but retained-plugin concurrency SHALL remain two while ten-chunk streams use the stated sender deadline. Queue wait MUST NOT exceed two seconds, and worker runtime MUST NOT exceed 20 seconds. The gateway's retained-plugin per-item core-call deadline SHALL default to 30 seconds, SHALL reserve at least three seconds beyond the configured maximum queue-plus-worker budget, and MUST NOT exceed the sender formula's 30-second wave slot. The lane SHALL expose queued and in-flight depth and bytes, queue wait, run duration, admission rejection, timeout, task exit, and completion-outcome telemetry.

#### Scenario: Retained plugin result replies after its durable terminus
- **GIVEN** a capability-retained plugin result is admitted within every item, byte, and per-agent bound
- **WHEN** core durably records both the raw result and its terminal handler outcome
- **THEN** the lane SHALL reply to the original caller with the durable outcome
- **AND** queue admission alone SHALL NOT transfer retry ownership

#### Scenario: Registered handler failure is durably recorded
- **GIVEN** a retained plugin result has been durably persisted
- **WHEN** a registered handler fails and that terminal failure is durably recorded
- **THEN** core SHALL treat the retained result's durable acceptance boundary as satisfied
- **AND** the gateway SHALL NOT request an endless retry of the already-owned raw result solely because the handler failed

#### Scenario: Raw result commits but handler outcome does not
- **GIVEN** a retained plugin result's raw row has committed
- **WHEN** the terminal handler outcome cannot be durably recorded
- **THEN** core SHALL report the retained result as uncommitted
- **AND** the gateway SHALL return `received: false`
- **AND** a retry SHALL converge idempotently without creating a duplicate raw logical result

#### Scenario: Saturated plugin lane does not block other status work
- **GIVEN** the retained plugin-result lane is at its concurrency or admitted-capacity limit
- **WHEN** unrelated status work or flow attribution reaches core
- **THEN** the shared routing mailbox remains available to classify that work
- **AND** plugin-result saturation does not consume the flow-attribution lane's item, byte, or worker budget

#### Scenario: Plugin admission exceeds a mandatory bound
- **GIVEN** accepting a retained plugin result would exceed the lane's total item, total retained-byte, or per-agent admitted limit across queued and in-flight work
- **WHEN** core evaluates admission
- **THEN** it SHALL reject the result with an explicit admission error
- **AND** it SHALL perform no expensive plugin-result ingest or registered-handler work inline in the shared routing mailbox

#### Scenario: Admitted plugin work fails before durable completion
- **GIVEN** a retained plugin result has been admitted
- **WHEN** it exceeds its queue-wait or worker deadline, its task exits, or durable persistence fails
- **THEN** the lane SHALL reply to the original caller with the corresponding explicit error
- **AND** the gateway SHALL map that uncommitted outcome to `received: false`

#### Scenario: Plugin lane telemetry accounts for work and memory
- **GIVEN** retained plugin results are admitted, executed, completed, timed out, or rejected
- **WHEN** the lane reports its operational state
- **THEN** its telemetry SHALL separately account for queued and in-flight depth and retained encoded bytes
- **AND** it SHALL record queue wait, worker duration, and the applicable completion or rejection outcome

### Requirement: Invalid status payloads remain hard RPC errors
The agent-gateway SHALL distinguish delivery failure from protocol invalidity. Malformed protobuf content, an undecodable source payload, a wire- or source-contract size violation, inconsistent stream identity or chunk metadata, and an agent-retained isolation violation SHALL terminate the affected RPC with a non-OK gRPC status. `INVALID_ARGUMENT` SHALL identify malformed, semantic, identity, or isolation violations; `RESOURCE_EXHAUSTED` with the bounded `payload_too_large` reason SHALL identify a payload above the 16 MiB chunk, 64 MiB stream, or applicable source-contract size limit. A syntactically valid payload that fits those protocol limits but exceeds the currently configured core lane capacity SHALL instead receive the normal retryable `received: false` response and MUST NOT be classified as poison. The sender SHALL treat only those terminal gRPC invalid-payload responses and its equivalent pre-RPC `ErrStreamStatusChunkTooLarge` or `ErrStreamStatusBudgetExceeded` validation outcomes as non-retryable for identical bytes, remove the complete offending agent-retained RPC set from its automatic pending queue as an explicit poison drop, increment bounded dropped-item and dropped-byte telemetry by reason, and permit later valid status work to continue. A local validation outcome SHALL NOT mark an otherwise healthy gateway connection disconnected; a terminal gRPC response MAY require reconnect before later work. The poison disposition SHALL NOT retain a second copy of the payload, count as durable receipt, or imply downstream persistence.

#### Scenario: Agent-retained source payload cannot be decoded
- **WHEN** an agent-retained service status contains malformed or semantically invalid source content
- **THEN** the agent-gateway SHALL terminate the affected RPC with a non-OK invalid-payload status
- **AND** it SHALL NOT enqueue the payload for later delivery
- **AND** it SHALL NOT return a successful response containing `received: false`

#### Scenario: Sender receives a non-retryable invalid-payload response
- **GIVEN** an agent-retained RPC receives a hard error identifying bytes that cannot become valid through retry
- **WHEN** the sender handles that terminal response
- **THEN** it SHALL stop automatically replaying the identical RPC set
- **AND** it SHALL remove the complete offending set as a terminal poison drop with bounded item, byte, and reason telemetry
- **AND** it SHALL NOT retain a second payload copy in a quarantine store
- **AND** later valid status work SHALL be able to proceed after the stream reconnects

#### Scenario: Sender rejects an oversized stream before opening the RPC
- **GIVEN** local stream validation returns `ErrStreamStatusChunkTooLarge` or `ErrStreamStatusBudgetExceeded` for an agent-retained RPC set
- **WHEN** the sender applies the terminal size disposition
- **THEN** it SHALL poison-drop the complete offending set using the same bounded item, byte, and reason telemetry
- **AND** it SHALL NOT mark an otherwise healthy gateway connection disconnected
- **AND** later valid status work SHALL proceed without replaying the invalid set

#### Scenario: Valid payload exceeds only the configured lane capacity
- **GIVEN** an agent-retained payload fits every wire and source-contract size limit
- **WHEN** the configured core lane cannot admit its item or byte size
- **THEN** the gateway SHALL complete the RPC with `received: false`
- **AND** the sender SHALL retain the complete set for retry rather than applying the poison disposition

#### Scenario: Stream metadata is inconsistent
- **WHEN** a `StreamStatus` RPC contains invalid chunk ordering, contradictory final-chunk metadata, or an agent identity that changes between chunks
- **THEN** the agent-gateway SHALL terminate the affected RPC with a non-OK protocol status
- **AND** it SHALL NOT acknowledge the stream as received

### Requirement: Volatile buffering excludes agent-retained statuses
The gateway `StatusBuffer` SHALL remain a bounded, volatile facility for best-effort statuses only. The gateway SHALL NOT enqueue `flow-attribution` or capability-retained `plugin-result` statuses into `StatusBuffer`, and SHALL NOT turn attempted buffer admission into a positive acknowledgement for either source. An agent-retained queue MAY be used only when the caller remains pending until durable completion and queue admission by itself is not acknowledged.

#### Scenario: Flow attribution forwarding fails
- **GIVEN** a valid isolated `flow-attribution` status
- **WHEN** its downstream delivery fails before durable commit
- **THEN** the `StatusBuffer` depth SHALL remain unchanged by that status
- **AND** the RPC SHALL complete with `received: false`

#### Scenario: Retained plugin-result forwarding fails
- **GIVEN** an agent negotiated `plugin-result-retained:v1`
- **WHEN** a valid isolated `plugin-result` status fails before durable commit
- **THEN** the gateway SHALL NOT place that status in `StatusBuffer`
- **AND** the RPC-wide acknowledgement SHALL be `received: false`

### Requirement: Best-effort buffer loss is accurately observable
For best-effort entries, `StatusBuffer` SHALL expose its bounded and volatile loss semantics. It SHALL report both current entry depth and retained encoded bytes. When overflow evicts an entry, drop telemetry SHALL identify and classify the actual evicted entry, not the incoming entry that was retained, and SHALL include bounded source and service-type dimensions plus dropped-item and dropped-byte totals by bounded reason. Operational documentation SHALL state that process or node shutdown can lose queued entries without per-entry recovery, and monitoring SHALL expose buffer entry/byte depth together with process or node restart signals so operators can identify possible restart-loss intervals. The system SHALL NOT claim an exact shutdown loss count when the process could not observe its own termination.

#### Scenario: Overflow evicts the oldest entry
- **GIVEN** a full `StatusBuffer` whose oldest entry differs in source, gateway, or partition from the incoming entry
- **WHEN** the incoming best-effort status is admitted and the oldest entry is evicted
- **THEN** drop telemetry SHALL use the evicted entry's identifying metadata
- **AND** the drop reason SHALL be `overflow`
- **AND** dropped-item, dropped-byte, and retained-byte measurements SHALL account for the evicted entry
- **AND** the incoming entry SHALL remain queued

#### Scenario: Restart can lose volatile entries
- **GIVEN** a non-zero best-effort buffer depth was most recently observed
- **WHEN** the buffer process or its node terminates and later restarts empty
- **THEN** operator documentation SHALL classify the prior queued entries as potentially lost
- **AND** monitoring SHALL expose the restart and surrounding buffer-depth observations
- **AND** the system SHALL NOT claim durable replay or an exact per-entry loss count that it cannot establish
