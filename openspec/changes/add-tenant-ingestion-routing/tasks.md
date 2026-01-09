## 1. Implementation
- [ ] 1.1 Add a tenant-scoped ingestion worker (GenServer) registered via Horde
- [ ] 1.2 Route sync status chunks from agent-gateway to the tenant worker using cluster registry lookups
- [ ] 1.3 Implement per-tenant backpressure with bounded in-flight chunk processing
- [ ] 1.4 Add queue/worker metrics and structured logs for ops visibility
- [ ] 1.5 Document operational behavior (auto-start, scaling, failure recovery)

## 2. Tests
- [ ] 2.1 Validate tenant worker ownership transfers on node failure
- [ ] 2.2 Validate backpressure behavior when tenant concurrency limit is reached
- [ ] 2.3 Validate large chunk routing does not require NATS
