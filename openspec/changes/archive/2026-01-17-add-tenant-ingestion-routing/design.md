## Context
Agent-gateway currently forwards sync result chunks directly to a core StatusHandler process. In multi-node deployments, this tends to concentrate ingestion on a single core node and provides no tenant-level backpressure.

## Goals / Non-Goals
- Goals:
  - Distribute ingestion work across core-elx nodes using ERTS process ownership.
  - Enforce per-tenant concurrency limits to protect CNPG and avoid noisy neighbors.
  - Preserve streaming gRPC chunking for large payloads.
  - Provide clear operational behavior (auto-start workers, no manual k8s tasks).
- Non-Goals:
  - Replacing streaming gRPC with NATS or another broker.
  - Changing DIRE identity resolution semantics.

## Decisions
- Decision: Introduce tenant-scoped ingestion workers registered in Horde.
  - Why: Horde provides ownership, failover, and node redistribution without manual orchestration.
- Decision: Agent-gateway routes sync chunks by tenant to the worker via registry lookup.
  - Why: Keeps the gRPC path direct and avoids an intermediate broker.
- Decision: Implement per-tenant backpressure via a bounded in-flight counter and queue.
  - Why: Prevents large tenants from exhausting the core DB pool.

## Ops Notes
- Workers start automatically when the first sync chunk arrives for a tenant or when tenant bootstrap runs; no k8s jobs/pods are added.
- Horizontal scaling is achieved by increasing core-elx replicas; Horde redistributes tenant workers across available nodes.
- Concurrency limits are configurable per tenant (optional) with cluster-wide defaults.

## Risks / Trade-offs
- Backpressure introduces latency for bursty tenants; metrics must surface queue depth.
- Worker placement depends on cluster health; node partitions can delay ingestion until rejoin.

## Migration Plan
- No schema changes required.
- Deploy core-elx changes; agent-gateway routing updated in the same release.

## Open Questions
- Default per-tenant concurrency (e.g., 2-4) vs. dynamic based on DB pool size.
- Whether to pre-warm workers at tenant bootstrap in high-scale environments.
