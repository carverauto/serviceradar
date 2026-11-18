## 1. Shared Elixir gRPC trace interceptors (serviceradar_core)

- [ ] 1.1 Server interceptor: extract W3C context from metadata and run the
      handler in a SERVER span with rpc.* attributes; status ERROR on raise
      or gRPC error
- [ ] 1.2 Client interceptor: CLIENT span per call and `traceparent` injected
      into request metadata
- [ ] 1.3 Tests at the interceptor boundary: an inbound `traceparent` becomes
      the server span's parent; outbound metadata carries the client span's
      context

## 2. Agent gateway

- [ ] 2.1 Register the server interceptor on `ServiceRadarAgentGateway.Endpoint`
- [ ] 2.2 Carry the ingest handler's span context on the edge-record
      publication and add `traceparent`/`tracestate` in
      `JetStreamPublisher.headers_for/2`
- [ ] 2.3 Test: a published edge record's headers carry the server span's
      trace and span id, and `EventWriter.Pipeline.batch_links/1` links it

## 3. Elixir datasvc clients

- [ ] 3.1 Attach the client interceptor to `DataService.Client` and
      `Sync.Client` channels

## 4. EventWriter

- [ ] 4.1 `starrocks.stream_load` CLIENT span around each
      `StarRocks.StreamLoad.persist/3` call (db.system=starrocks,
      db.collection.name, row count, ERROR status), created only when the
      caller has an active span; `Destination.load_chunks/6` attaches the
      caller's context in each parallel task before `persist/3`
- [ ] 4.2 `edge_record.ingest` CLIENT span around each edge-record ingest
      transaction (db.system=postgresql, output contract, outcome), created
      only when a span is active
- [ ] 4.3 Tests: each persistence span is a child of the active batch span,
      including chunks loaded in parallel tasks, the Stream Load span carries
      ERROR status on failure, and no
      persistence span is created when no span is active
- [ ] 4.4 Producer carries the delivering stream's filter subject as
      `:destination_template`; the batch span's `messaging.destination.name`
      uses it
- [ ] 4.5 Test: a batch delivered on a subject that embeds a series key
      records the template, not the concrete subject

## 5. Root-span-ratio worker

- [ ] 5.1 Breach warning: state that the roots carry neither a parent nor a
      link, without naming a cause, and list the top contributors (service,
      kind, roots); threshold, window, floor and linked-consumer exclusion
      unchanged

## 6. Demo validation (supersedes refactor-otel-signal-correlation 4.5)

- [ ] 6.1 After the rollout, run the checks in design.md "Measurement", each
      with an explicit failure branch
- [ ] 6.2 Record the measured ratio in this change before archiving
