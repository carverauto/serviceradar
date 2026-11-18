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

### D1. Batch consumer spans keep links and gain one store child span

`event_writer.process_batch` stays a CONSUMER root that links to up to
`@max_batch_links` upstream contexts. The OTel messaging conventions say a
batch receive/process span links its producers rather than picking one as
parent, and the worker already excludes linked consumer roots.

Inside it, the processor's persistence step (`store/2`: warehouse Stream Load
or CNPG insert) runs as a CLIENT child span `event_writer.store` with
`db.system` (`starrocks` or `postgresql`), `db.collection.name`, the row count
and status ERROR on failure. That is one span per batch.

Alternatives rejected:

- Re-enable OpentelemetryEcto by default. It produces many children, but it
  is the per-query, pre-sampler cost that `8fb046776d` removed for CPU
  reasons.
- One span per message. Batches carry up to hundreds of messages, so this
  multiplies span volume for no diagnostic gain.
- Parenting the batch span on the first message's context. That misattributes
  the other N-1 messages and contradicts the messaging conventions.

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
and carries its encoded `traceparent` on the publication map.
`JetStreamPublisher.headers_for/2` adds it to the NATS headers. The context is
captured in the handler and does not come from the publisher process's own
context, because the publish runs in a publisher lane process that has none.
`batch_links/1` already deduplicates links by trace and span id, so the many
records from one stream collapse to one link per batch.

Alternative rejected: a PRODUCER span per edge record. It is the textbook
"create" span, but it costs one span per record on the gateway's hottest
path. A link to the stream's server span already ties the record to the
agent's delivery.

Open question for approval: whether to also add `tracestate`. It is
recommended, because it costs nothing and the propagator handles it.

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

### D4. RootSpanRatioWorker: unchanged signal, accurate message

The threshold (0.85), window (15 m), floor and linked-consumer exclusion stay
as they are. The breach warning stops asserting ingest loss. It says roots are
missing a parent or link, either because producers did not propagate context
or because ingest dropped it. It also lists the top contributors (service
name, span kind, root count) from one extra grouped query that runs only on
breach.

Alternative considered: measure only "entry" spans (SERVER/CONSUMER without
parent or link). That signal is more precise, but it narrows what counts and
reads as loosening. Revisit it once D1-D3 land and the measured ratio is
known.

## Risks / Trade-offs

- A long-lived gateway stream span ends, and is exported, only when the stream
  closes. Until then its children and linked consumers reference a span not yet
  stored, and the trace view shows them as orphans. That is acceptable: the
  agent rotates streams, and the waterfall already tolerates missing parents.
- Span volume roughly doubles, from about 7.1k/h to about 15k/h on demo. Spans
  are cheap relative to the flows and edge records they describe.
- Sampling: core-elx uses `parent_based(root: ratio)`. Deployments at the
  default 0.05 keep 5% of the new CLIENT roots and all of their children.
  That works as intended.

## Measurement

The acceptance check runs after the rollout finishes, against spans with
`timestamp` later than the newest pod start:

- The warehouse root ratio over 1 h is below the 0.85 threshold.
- `serviceradar-agent-gateway` SERVER spans exist, and their `parent_span_id`
  equals an agent CLIENT `span_id` in the same trace.
- `event_writer.store` children exist, and their parent is a stored
  `process_batch` span.
- Edge-record `process_batch` spans carry non-empty `links`.
- The check fails explicitly when any of these counts is zero.
