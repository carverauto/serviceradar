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
The agent gateway SHALL stamp W3C `traceparent` on every edge-record JetStream publication, taken from the ingest RPC's span context, so the EventWriter batch span links to the agent's delivery.

#### Scenario: Edge-record batch links to the delivering stream
- **GIVEN** an agent delivers edge records over `EdgeRecordIngestService/Stream`
- **WHEN** EventWriter processes a batch of those records
- **THEN** the `event_writer.process_batch` span SHALL carry a link to the gateway span that published them

### Requirement: EventWriter batch spans record their store step
EventWriter SHALL run each traced batch's persistence step as a CLIENT child span of `event_writer.process_batch`, carrying the database system, the target collection, the row count, and status ERROR when the store fails.

Telemetry subjects (`otel.>`, `logs.>`, `metrics.>`) remain untraced.

#### Scenario: Store child span
- **WHEN** EventWriter persists a batch from a non-telemetry subject
- **THEN** an `event_writer.store` span SHALL be stored with `parent_span_id` equal to the batch span's `span_id`

### Requirement: Messaging span destinations are bounded
NATS producer and consumer spans SHALL record `messaging.destination.name` as a subject template drawn from a bounded set (a configured stream filter subject or a fixed subject family), and SHALL NOT record a concrete subject that embeds entity identifiers, series keys, or device addresses.

#### Scenario: Per-series subject is recorded as its template
- **GIVEN** EventWriter consumes a message on `signals.analytics.predictions.<series key>` through a stream filtered on `signals.analytics.predictions.>`
- **WHEN** the batch span is exported
- **THEN** `messaging.destination.name` SHALL equal `signals.analytics.predictions.>`
- **AND** no span attribute SHALL contain the series key

### Requirement: Root-span ratio breach names its contributors
The root-span-ratio health signal SHALL report a breach without asserting a single cause, and SHALL include the services and span kinds contributing the most unparented, unlinked roots. Its threshold, window, floor, and linked-consumer exclusion are unchanged by this requirement.

#### Scenario: Breach warning is actionable
- **WHEN** the ratio exceeds the threshold
- **THEN** the warning SHALL list the top contributing `(service_name, kind)` pairs with their root counts
