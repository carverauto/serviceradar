# mtr-diagnostics Delta

## MODIFIED Requirements

### Requirement: On-Demand MTR Execution
The agent SHALL support on-demand MTR execution through the ControlStream command
interface. ControlStream SHALL return bounded command/progress state and a stable
trace identifier; the complete enriched trace SHALL use the same canonical
durable MTR event contract as scheduled, sweep-profile, and ad-hoc traces while
remaining in the shared platform route selected by its scheduler-attested
immutable traffic class.

#### Scenario: On-demand trace succeeds
- **WHEN** an authorized `mtr.run` command is received with a target address
- **THEN** the agent SHALL execute one bounded MTR trace and assign a stable
  trace ID correlated to the command
- **AND** the command response SHALL report accepted/progress/terminal state and
  the trace ID
- **AND** the complete ASN, DNS, MPLS, ECMP, hop, reachability, and timing result
  SHALL be published through `MtrTraceBatchV1`
- **AND** an on-demand trace classified as interactive SHALL use the shared
  interactive edge-record lane, physical stream, durable, and result credits

#### Scenario: On-demand trace via control stream
- **WHEN** an authorized `mtr.run` command is received via ControlStream with a
  target address
- **THEN** the agent SHALL execute one bounded MTR trace to the specified
  target, enriched with ASN, DNS, and MPLS data
- **AND** the control stream response SHALL carry bounded command/progress state
  and the trace ID rather than the complete enriched result
- **AND** the complete result SHALL be published through `MtrTraceBatchV1` as
  described in "On-demand trace succeeds"

#### Scenario: Caller waits for an interactive result
- **GIVEN** the trace completes within the command's bounded response window
- **WHEN** the terminal response is returned
- **THEN** it MAY contain a bounded display summary
- **AND** durable persistence and downstream processing SHALL still use the
  canonical MTR event rather than a direct core/database write

### Requirement: TimescaleDB Storage
The MTR event-writer consumer SHALL persist canonical trace events into
TimescaleDB hypertables (`mtr_traces` for trace metadata and `mtr_hops` for
bounded hop/path-variant observations) using stable keys and one bounded,
idempotent transaction per source event or bounded compatible source-event group.
Every event in a group SHALL retain independent ledger/slot semantics and an
explicit post-commit JetStream ACK. ASN values SHALL be represented without
signed overflow, and absent measurements SHALL remain distinguishable from zero.
The hop ASN column SHALL be wide enough to hold the FULL `uint32` domain the ABI
admits -- a signed 32-bit column cannot, and would silently make the whole
32-bit private-use range unrepresentable -- and a zero ASN, which the ABI defines
as unavailable or not supplied, SHALL be persisted as SQL `NULL` rather than as
`0`, which would otherwise read as an observation of AS 0.
V1 `trace_id` SHALL be an RFC 9562 UUIDv7 allocated and durably recorded before
probing. `trace_identity_time` SHALL be derived only from that UUIDv7 timestamp
and used as the Timescale partition key. The consumer SHALL validate the trace's
authoritative observation/completion time (not only the UUIDv7 identity time)
against the signed collection interval plus attested-clock tolerance, and SHALL
require `trace_identity_time` to be consistent with that authoritative
observation time. The trace row SHALL uniquely bind
`(trace_identity_time, network_scope_id, trace_id)` to authenticated agent,
traffic class, source/context, execution/check/command, canonical target,
observation time, content digest, and event. Hop rows SHALL reference that
physical key. A bounded partitioned summary-first expectation MAY exist only
until trace or terminal reconciliation resolves it; the system SHALL NOT retain
a permanent non-hypertable identity row per completed trace. UUID-backed IDs
SHALL use one canonical form;
nanosecond wire time SHALL follow the shared deterministic PostgreSQL-microsecond
conversion while retaining original nanoseconds where required.

#### Scenario: Trace event is ingested
- **WHEN** a canonical MTR trace event is consumed
- **THEN** one trace row SHALL be inserted or replay-safely matched by stable
  trace identity
- **AND** its hop/path-variant rows SHALL preserve full MPLS labels, ASN,
  hostname, counts, loss, RTT, jitter, and reachability semantics
- **AND** JetStream SHALL be acknowledged only after the transaction commits

#### Scenario: Trace ingestion into hypertables
- **WHEN** an MTR trace result is produced for storage
- **THEN** its `mtr_traces` row and per-hop `mtr_hops` rows (full statistics,
  MPLS labels, ASN, hostname) SHALL be written by the MTR event-writer consumer
  from the canonical trace event, as described in "Trace event is ingested"
- **AND** the core system SHALL NOT insert trace or hop rows through a direct
  write that bypasses that consumer

#### Scenario: A zero hop ASN is persisted as NULL
- **WHEN** a hop's `asn` is zero, whether omitted on the wire or explicitly encoded
- **THEN** the persisted column SHALL be SQL `NULL`
- **AND** it SHALL NOT be stored as `0`, which would read as an observation of AS 0

#### Scenario: The full uint32 ASN domain survives projection
- **WHEN** a hop carries `asn = 4294967295`, or any value above 2147483647 such as the
  32-bit private-use range 4200000000-4294967294
- **THEN** the persisted value SHALL equal the value the ABI admitted
- **AND** it SHALL NOT be truncated, wrapped, or rejected by the column's width

#### Scenario: Trace event is redelivered
- **WHEN** the same `(network_scope_id, event_id)` is delivered repeatedly with a
  matching stored `semantic_envelope_sha256`
- **THEN** the ingest ledger and domain uniqueness constraints SHALL prevent
  duplicate trace and hop rows
- **AND** the consumer SHALL treat the already committed event as success

#### Scenario: Trace body observation time is outside the collection interval
- **WHEN** a trace event's UUIDv7 identity time falls inside the signed
  collection interval but its authoritative body observation time falls outside
  that interval
- **THEN** the consumer SHALL reject or quarantine the event rather than commit it
- **AND** SHALL NOT create a trace or hop row under that identity

#### Scenario: Trace identity is reused for different content
- **WHEN** the same network-scope-scoped trace ID carries a different observation
  time, traffic class, authorization binding, or trace/hop content
- **THEN** the consumer SHALL classify it as an integrity conflict
- **AND** SHALL NOT create a second historical trace under that identity

#### Scenario: Same trace ID races across time chunks
- **WHEN** concurrent events claim one network-scope/trace ID with different
  observation times or claimed partition placement
- **THEN** both SHALL derive the same `trace_identity_time` from the UUIDv7 and
  contend on the same trace-row unique key
- **AND** placement outside the signed collection interval SHALL be rejected
- **AND** only the first authenticated trace/hop binding SHALL remain canonical

#### Scenario: Historical query by target
- **WHEN** an authorized caller queries retained MTR history for one network
  scope, target, and time range
- **THEN** trace results SHALL be returned in observation-time order
- **AND** complete retained hop data SHALL be available for each trace
- **AND** every trace/hop/identity/correlation join SHALL include the authorized
  `network_scope_id`

#### Scenario: Another network scope has the same trace or target identifier
- **GIVEN** two sites reuse an RFC1918 target or trace identifier
- **WHEN** a caller queries one network scope by trace ID, execution, target, or
  time range
- **THEN** storage policy and query predicates SHALL exclude every other network
  scope's trace, hop, correlation, rollup, and repair state
- **AND** an unscoped trace-ID lookup SHALL be rejected
