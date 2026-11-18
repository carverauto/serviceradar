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

- [ ] 4.1 `event_writer.store` CLIENT child span around the processor's
      persistence step (db.system, collection, row count, ERROR status)
- [ ] 4.2 Test: the store span is a child of the batch span and carries ERROR
      status when the store fails

## 5. Root-span-ratio worker

- [ ] 5.1 Breach warning: accurate cause wording plus top contributors
      (service, kind, roots); threshold, window and exclusions unchanged

## 6. Demo validation (supersedes refactor-otel-signal-correlation 4.5)

- [ ] 6.1 After the rollout, run the checks in design.md "Measurement", each
      with an explicit failure branch
- [ ] 6.2 Record the measured ratio in this change before archiving
