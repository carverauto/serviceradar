# Change: Refactor results ingestion routing (sync + sweep)

## Why
Sweep results currently rely on NATS EventWriter ingestion while sync results flow through the gRPC/ERTS status pipeline. This split makes results handling inconsistent, adds avoidable coupling to JetStream for sweep, and obscures the gRPC results path responsibilities.

## What Changes
- Route sweep results through the gRPC/ERTS results pipeline (agent-gateway → core ingestor), eliminating the NATS EventWriter dependency for sweep ingestion.
- Replace the special-case StatusHandler sync-only logic with a dedicated results router/ingestor module that handles sync and sweep results explicitly.
- Keep tenant isolation enforced at the gateway (mTLS metadata) and in the core ingestion path.

## Impact
- Affected specs: edge-architecture
- Affected code: agent-gateway status processing, core results ingestion, sweep ingestion pipeline, EventWriter sweep processor
