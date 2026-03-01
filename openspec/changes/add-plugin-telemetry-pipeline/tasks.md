## 1. Implementation
- [ ] 1.1 Define gRPC/ERTS telemetry envelopes for plugin events + logs (batch payload).
- [ ] 1.2 Update agent plugin runtime to emit telemetry batches (events + logs) separate from results.
- [ ] 1.3 Add gateway forwarding for plugin telemetry batches.
- [ ] 1.4 Add core-elx ingestion for plugin telemetry (map to OCSF events + OTEL logs).
- [ ] 1.5 Publish OCSF events to `events.ocsf.processed` and log records to the OTEL/logs subject(s).
- [ ] 1.6 Add schema validation and size limits for telemetry payloads.
- [ ] 1.7 Add SDK helpers for OCSF events and OTEL-style logs.
- [ ] 1.8 Add docs + examples showing plugin events/logs pipeline.
- [ ] 1.9 Add tests for payload validation and ingestion (agent/gateway/core).
