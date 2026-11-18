## ADDED Requirements

### Requirement: Platform gRPC hops produce parented spans
ServiceRadar's Elixir gRPC servers and clients SHALL propagate W3C trace context on platform gRPC calls. A server SHALL run each RPC in a SERVER span whose parent is the caller's propagated context. A client SHALL inject its CLIENT span's context into the request metadata.

The agent gateway endpoint and the Elixir datasvc clients are the required
adopters.

#### Scenario: Agent call to the gateway yields a two-span trace
- **GIVEN** the agent calls an `AgentGatewayService` RPC with a `traceparent` in the gRPC metadata
- **WHEN** the gateway handles the call
- **THEN** the gateway SHALL export a SERVER span whose `trace_id` equals the agent span's `trace_id`
- **AND** whose `parent_span_id` equals the agent CLIENT span's `span_id`

#### Scenario: Elixir call to datasvc carries context
- **WHEN** core-elx calls a datasvc KV or DataService RPC
- **THEN** the request metadata SHALL carry a `traceparent` naming the core-elx CLIENT span
- **AND** the datasvc SERVER span SHALL be stored with that span as its parent

### Requirement: Edge-record publications carry trace context
The agent gateway SHALL stamp W3C `traceparent` and `tracestate` on every edge-record JetStream publication, taken from the ingest RPC's span context, so the EventWriter batch span links to the agent's delivery.

#### Scenario: Edge-record batch links to the delivering stream
- **GIVEN** an agent delivers edge records over `EdgeRecordIngestService/Stream`
- **WHEN** EventWriter processes a batch of those records
- **THEN** each published message SHALL carry `traceparent` and `tracestate` headers taken from the gateway's ingest span context
- **AND** the `event_writer.process_batch` span SHALL carry a link to the gateway span that published them

### Requirement: EventWriter persistence clients record child spans
EventWriter persistence clients SHALL record a CLIENT span for each StarRocks Stream Load and each edge-record ingest transaction when a span is already active, and SHALL NOT create such a span when no span is active.

The `starrocks.stream_load` span carries `db.system=starrocks`, `db.collection.name` set to the target table, the row count, and status ERROR on failure. The `edge_record.ingest` span carries `db.system=postgresql`, the output contract, and the outcome. Other CNPG writes are covered only by the opt-in Ecto tracing. Telemetry subjects (`otel.>`, `logs.>`, `metrics.>`) remain untraced.

#### Scenario: Stream Load child span
- **GIVEN** an `event_writer.process_batch` span is active
- **WHEN** the processor persists rows through a StarRocks Stream Load
- **THEN** a `starrocks.stream_load` span SHALL be stored with `parent_span_id` equal to the batch span's `span_id`
- **AND** its `db.collection.name` SHALL name the target table
- **AND** its status SHALL be ERROR when the Stream Load fails

#### Scenario: Edge-record ingest child span
- **GIVEN** an `event_writer.process_batch` span is active for an edge-record batch
- **WHEN** the processor runs an edge-record ingest transaction
- **THEN** an `edge_record.ingest` span SHALL be stored with `parent_span_id` equal to the batch span's `span_id`
- **AND** it SHALL carry `db.system=postgresql`, the output contract, and the outcome

#### Scenario: No persistence span without an active span
- **GIVEN** no span is active
- **WHEN** a Stream Load or an edge-record ingest transaction runs
- **THEN** no `starrocks.stream_load` or `edge_record.ingest` span SHALL be created

### Requirement: Messaging span destinations are bounded
NATS producer and consumer spans SHALL record `messaging.destination.name` as a subject template drawn from a bounded set (a configured stream filter subject or a fixed subject family), and SHALL NOT record a concrete subject that embeds entity identifiers, series keys, or device addresses.

#### Scenario: Per-series subject is recorded as its template
- **GIVEN** EventWriter consumes a message on `signals.analytics.predictions.<series key>` through a stream filtered on `signals.analytics.predictions.>`
- **WHEN** the batch span is exported
- **THEN** `messaging.destination.name` SHALL equal `signals.analytics.predictions.>`
- **AND** no span attribute SHALL contain the series key

### Requirement: Root-span ratio breach names its contributors
The root-span-ratio health signal SHALL report a breach as roots that carry neither a parent nor a link, without naming a cause, and SHALL include the services and span kinds contributing the most unparented, unlinked roots. Its threshold, window, floor, and linked-consumer exclusion are unchanged by this requirement.

#### Scenario: Breach warning is actionable
- **WHEN** the ratio exceeds the threshold
- **THEN** the warning SHALL list the top contributing `(service_name, kind)` pairs with their root counts
