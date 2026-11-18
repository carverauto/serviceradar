# Change: Produce connected platform traces across gRPC and NATS hops

## Why

`RootSpanRatioWorker` has reported a root-span ratio of 1.0 on demo for as
long as logs go back. In the warehouse, roots equal total spans on every day
since its first row (2026-10-19). The worker blames ingest ("parent span
linkage is likely being lost at ingest"), but it has the cause wrong: the
parent linkage is never produced.

Evidence (demo, 2026-11-17):

- Every OTLP span retained on `otel.traces.raw` (3,616 spans in 1,058
  messages, decoded from the `events` stream with read-only `nats stream get`)
  carries an empty `parent_span_id`. The collector (`rust/otel`
  `handle_traces`) republishes the request unmodified, so EventWriter and the
  StarRocks row mapping store exactly what producers send. The two child
  spans the warehouse holds for the last 7 days kept their parent ids, which
  shows the pipeline keeps a parent id when one exists.
- What the producers emit, per span:
  - core-elx `event_writer.process_batch` (CONSUMER): about 88% of spans. Each
    batch produces exactly one span, with no children. A batch span gets a
    link only when the NATS publisher stamped `traceparent`, and only
    `events.ocsf.processed` and analytics predictions do. The main subjects,
    edge records (`telemetry.edge-record.v1.bulk.*`, published by the agent
    gateway), raw flows and flow-attribution observations, carry no trace
    context.
  - agent (Go `otelgrpc` CLIENT) calls to `AgentGatewayService/*` and
    `EdgeRecordIngestService/Stream`: these are real trace roots. Their
    server half never exists, because `serviceradar_agent_gateway` attaches no
    instrumentation (`OtelSetup.attach_instrumentations(instrumentations: [])`)
    and its gRPC endpoint neither extracts the inbound `traceparent` the agent
    sends nor starts a server span.
  - datasvc (Go `otelgrpc` SERVER) `KVService/Get` and `DataService/*`: the
    Elixir gRPC clients (`ServiceRadar.DataService.Client`,
    `ServiceRadar.Sync.Client`) inject no `traceparent`, so every server span
    is a root.
  - web-ng Phoenix SERVER spans and core-elx `internal_log.persist` have no
    child spans.
- The roughly 17% of child spans seen in June 2026
  (`refactor-otel-signal-correlation`, design table) came from
  OpentelemetryEcto/OpentelemetryOban. Commit `8fb046776d` (2026-06-24) made
  both opt-in, defaulting off, because they build a span for every query or job
  before the sampler runs. Demo enables neither, and its
  `OTEL_TRACES_SAMPLER_ARG` is 1.0, so sampling is not the cause.

`refactor-otel-signal-correlation` marked Elixir gRPC client propagation
(task 4.1) as done, but no Elixir gRPC stub injects context. Tasks 4.3 (Rust)
and 4.5 (demo validation: "root-span ratio drops below threshold") remain
open, and the demo data shows the propagation work was never finished.
`add-otel-messaging-sdk` describes the root-span problem as fixed; it is not.

## What Changes

- **Agent gateway gRPC server spans.** A project-owned gRPC server interceptor
  on the agent-gateway endpoint extracts W3C trace context from request
  metadata and runs each RPC inside a SERVER span. Agent CLIENT spans then
  gain a child on the gateway.
- **Edge-record publish carries context.** The gateway stamps the ingest
  RPC's `traceparent`/`tracestate` on each JetStream edge-record publication,
  so the EventWriter batch span links back to the agent's delivery.
- **Elixir gRPC client propagation.** A project-owned gRPC client interceptor
  starts a CLIENT span and injects `traceparent` into outbound metadata for
  the datasvc KV and DataService stubs. The datasvc SERVER span becomes its
  child.
- **EventWriter persistence clients record child spans.** When a span is
  already active, each StarRocks Stream Load runs as a CLIENT span
  `starrocks.stream_load` and each edge-record ingest transaction runs as a
  CLIENT span `edge_record.ingest`. Under `event_writer.process_batch` they
  show where batch time goes. Neither ever starts a root, so telemetry-subject
  stores stay untraced. They cost one span per Stream Load or edge-record
  transaction, not one per query, so Ecto and Oban tracing stay opt-in.
- **Bounded messaging destination attributes.** NATS spans record a subject
  template (the delivering stream's filter subject), never a concrete
  subject. The analytics-prediction subject embeds a series key that
  hex-encodes device identity and metric values.
- **Root-span-ratio alert names the real failure.** The threshold and window
  are unchanged. The warning stops asserting ingest loss and names the
  services and span kinds that contribute the most unparented roots, so the
  alert can be acted on.

Not in scope: Rust service propagation (`rust/kvutil`, flow collector). Those
callers have no active tracer to propagate from today, and raw flows start
outside the platform, so their consumer roots are legitimate. Also out of
scope are trace context on JetStream subjects whose publishers create no
spans, and re-enabling Ecto/Oban tracing by default.

## Impact

- Affected specs: `observability-signals` (ADDED requirements). The change
  completes and supersedes tasks 4.3 and 4.5 of
  `refactor-otel-signal-correlation`.
- Affected code:
  - `elixir/serviceradar_agent_gateway`: endpoint interceptor, edge-record
    publish headers.
  - `elixir/serviceradar_core`: `Otel` gRPC client and server interceptors,
    `DataService.Client` and `Sync.Client` connections,
    `EventWriter.Producer` destination template, `EventWriter.Pipeline`
    destination attribute, `Analytics.StarRocks.StreamLoad` and the
    `EdgeRecord` processor persistence spans,
    `Jobs.RootSpanRatioWorker` warning text and breakdown.
- Span volume: about one additional span per gateway RPC or stream, one per
  Elixir datasvc call, plus the EventWriter persistence spans (one per Stream
  Load and one per edge-record transaction). Demo's current rate is about
  7.1k spans/h. The edge-record span follows ingest record volume, so the new
  rate is measured after rollout against the warehouse budget.
- Expected demo outcome, from the measured mix: the ratio falls from 1.0 to
  about 0.2-0.3 because stored spans carry real parent ids and links, with the
  0.85 threshold unchanged.
