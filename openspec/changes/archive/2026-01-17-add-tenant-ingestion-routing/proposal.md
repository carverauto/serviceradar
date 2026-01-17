# Change: Tenant-aware ingestion routing and backpressure

## Why
Sync ingestion work is currently routed to a single core-elx node per stream and executed immediately, which makes bursty tenants monopolize resources and makes scaling unpredictable in multi-node deployments.

## What Changes
- Route sync result chunks to tenant-scoped ingestion workers registered in the ERTS cluster.
- Add per-tenant backpressure (bounded in-flight chunks) with queueing and visibility.
- Define operational lifecycle: workers start automatically on demand or at tenant bootstrap; scaling is done by adding core-elx pods, not by manual worker provisioning.
- Keep streaming gRPC chunking; do not add NATS to this path.

## Impact
- Affected specs: ingestion-routing (new)
- Affected code: elixir/serviceradar_agent_gateway/**, elixir/serviceradar_core/**
- Ops: core-elx deployment scale impacts throughput; no extra k8s workloads required
