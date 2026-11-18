# Design: connected platform traces

## Context

The proposal lists the evidence: every span on the wire is a root, and the
pipeline stores parent ids faithfully. The fix belongs at the producers. Four
producer gaps account for the whole demo span mix:

| Producer | Share of spans | Gap |
| --- | --- | --- |
| core-elx `event_writer.process_batch` (CONSUMER) | ~88% | No children; links only when the publisher sent `traceparent` |
| agent `otelgrpc` CLIENT to the gateway | ~7% | Gateway emits no server span and ignores the inbound `traceparent` |
| datasvc `otelgrpc` SERVER | ~3% | Elixir gRPC clients inject nothing |
| web-ng / core-elx INTERNAL and SERVER | ~1% | No children (Ecto/Oban tracing is opt-in, default off) |

## Goals / Non-Goals

- Goal: stored spans carry real parent ids and links for the platform's own
  gRPC and NATS hops, so the root-span ratio measures propagation health
  again.
- Goal: keep the per-operation span cost bounded. Nothing here adds a span
  per database query or per Oban poll.
- Non-goal: loosening `RootSpanRatioWorker` (threshold, window, or which
  spans count).
- Non-goal: Rust service propagation and publishers that create no spans
  (flow collector, zen). Their consumer roots are legitimate trace starts.

## Decisions

All decisions below were approved as written on 2026-11-17.

### D1. Batch consumer spans keep links; persistence clients record child spans

`event_writer.process_batch` stays a CONSUMER root that links to up to
`@max_batch_links` upstream contexts. The OTel messaging conventions say a
batch receive/process span links its producers rather than picking one as
parent, and the worker already excludes linked consumer roots.

Processors have no single per-batch store step: the `EdgeRecord` processor
runs one CNPG transaction per record, and warehouse processors call
`StarRocks.StreamLoad.persist/3` one or more times per batch. CLIENT spans
therefore sit at the real persistence clients, and each is created only when a
span is already active. They never start a root, so telemetry-subject stores,
which deliberately have no batch span, never trace themselves.

The active span is the caller's. `Destination.load_chunks/6` runs chunked
Stream Loads in `Task.async_stream` tasks, which do not inherit the caller's
context, so it captures the caller's context and attaches it in each task
before `persist/3`. A caller with no span still produces none.

- `starrocks.stream_load`: one per StarRocks Stream Load, with
  `db.system=starrocks`, `db.collection.name=<table>`, the row count and
  status ERROR on failure.
- `edge_record.ingest`: one per edge-record ingest transaction, with
  `db.system=postgresql`, the output contract and the outcome.

Other CNPG writes stay covered only by the existing opt-in Ecto tracing.

The user approved this amendment on 2026-11-17.

Alternatives rejected:

- Re-enable OpentelemetryEcto by default. It produces many children, but it
  is the per-query, pre-sampler cost that `8fb046776d` removed for CPU
  reasons.
- One span per message. Batches carry up to hundreds of messages, so this
  multiplies span volume for no diagnostic gain.
- Parenting the batch span on the first message's context. That misattributes
  the other N-1 messages and contradicts the messaging conventions.
- A span wrapping `processor.process_batch/1`. It duplicates the parent's
  duration and says nothing about where the time goes.

### D2. Agent gateway: server interceptor plus context on the edge-record publish

A project-owned `GRPC.Server.Interceptor` (in `serviceradar_core`, so web-ng
and core can reuse it) does three things:

1. Extracts `traceparent`/`tracestate` from request metadata with
   `:otel_propagator_text_map`.
2. Runs the handler inside a SERVER span named `<package.Service>/<Method>`
   with `rpc.system=grpc`, `rpc.service` and `rpc.method`.
3. Sets status ERROR when the handler raises or returns a gRPC error.

It is registered on `ServiceRadarAgentGateway.Endpoint` next to the
safe-logger interceptor. Unary RPCs get one span per call. Streaming RPCs get
one span for the stream's lifetime, which matches the agent's `otelgrpc`
client span for that stream.

Edge-record publication: the ingest handler captures the active span context
and carries its encoded `traceparent` and `tracestate` on the publication map.
`JetStreamPublisher.headers_for/2` adds both to the NATS headers. The context is
captured in the handler and does not come from the publisher process's own
context, because the publish runs in a publisher lane process that has none.
`batch_links/1` already deduplicates links by trace and span id, so the many
records from one stream collapse to one link per batch.

Alternative rejected: a PRODUCER span per edge record. It is the textbook
"create" span, but it costs one span per record on the gateway's hottest
path. A link to the stream's server span already ties the record to the
agent's delivery.

Both `traceparent` and `tracestate` are stamped (approved 2026-11-17).

### D3. Elixir gRPC client interceptor for datasvc calls

A project-owned `GRPC.Client.Interceptor` starts a CLIENT span per call
(named after the RPC) and injects `traceparent` into the request metadata.
It is attached where `ServiceRadar.DataService.Client` and
`ServiceRadar.Sync.Client` connect their channels. When no span is active,
the CLIENT span is itself a root and the datasvc SERVER span becomes its
child.

Alternative rejected: inject only when a span is already active. Most datasvc
calls run outside any span (config reads, sync), so this would change nothing
for the measured traffic.

### D4. Messaging destination attributes are bounded

`messaging.destination.name` on NATS spans SHALL name a subject template,
never a concrete subject that embeds an entity. Today the EventWriter batch
span records the delivered subject. For analytics predictions that subject is
`signals.analytics.predictions.<series key>`, and the key built by
`rust/anomaly-addon` `series_key_for` hex-encodes the partition, the device
identity (an IP address) and the metric. The attribute is therefore
unbounded and carries device identity into every span.

The template is the filter subject of the configured JetStream stream that
delivered the message. The producer already resolves it
(`configured_stream/3`) and now carries it in message metadata as
`:destination_template`, for example `signals.analytics.predictions.>` or
`telemetry.edge-record.v1.bulk.>`. The configuration bounds that set.

Inventory of NATS span sites (2026-11-17): the EventWriter batch span, which
this decision changes, and `StateChangePublisher` `state_change.publish`,
whose subject is `signals.state.<table>` with `table` a literal at every
caller (`service_state`, `ocsf_devices`, `health_events`) and therefore
already bounded. Go and Rust services emit no messaging spans. The
gateway's new spans carry `rpc.*` attributes only.

### D5. RootSpanRatioWorker: unchanged signal, accurate message

The threshold (0.85), window (15 m), floor and linked-consumer exclusion stay
as they are. The breach warning stops asserting ingest loss. It states that
the roots carry neither a parent nor a link, without naming a cause, and lists
the top contributors (service name, span kind, root count) from one extra
grouped query that runs only on breach.

Alternative considered: measure only "entry" spans (SERVER/CONSUMER without
parent or link). That signal is more precise, but it narrows what counts and
reads as loosening. Revisit it once D1-D4 land and the measured ratio is
known.

## Risks / Trade-offs

- A long-lived gateway stream span ends, and is exported, only when the stream
  closes. Until then its children and linked consumers reference a span not yet
  stored, and the trace view shows them as orphans. That is acceptable: the
  agent rotates streams, and the waterfall already tolerates missing parents.
- Span volume: one extra span per gateway RPC or stream, one per datasvc call,
  plus the D1 persistence spans (one per Stream Load and one per edge-record
  transaction). Edge-record transactions follow record volume, so that span
  scales with the gateway's ingest rate. Spans are cheap relative to the flows
  and edge records they describe.
- Sampling: core-elx uses `parent_based(root: ratio)`. Deployments at the
  default 0.05 keep 5% of the new CLIENT roots and all of their children.
  That works as intended.

## Measurement

The acceptance check runs after the rollout finishes, against spans with
`timestamp` later than the newest pod start:

- The warehouse root ratio over 1 h is below the 0.85 threshold.
- `serviceradar-agent-gateway` SERVER spans exist, and their `parent_span_id`
  equals an agent CLIENT `span_id` in the same trace.
- `starrocks.stream_load` and `edge_record.ingest` children exist, and their
  parent is a stored `process_batch` span.
- Edge-record `process_batch` spans carry non-empty `links`.
- The check fails explicitly when any of these counts is zero.
