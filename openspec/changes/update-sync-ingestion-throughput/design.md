## Context
Sync results arrive in multiple chunks from the agent-gateway. The core StatusHandler processes each chunk synchronously and the SyncIngestor updates devices with per-row updates, which creates long queues and slow end-to-end sync completion.

## Goals / Non-Goals
- Goals:
  - Remove chunk-level blocking by running ingestion asynchronously.
  - Smooth bursty chunk delivery using a tenant-scoped ingestion queue with coalescing.
  - Increase throughput with bounded parallel batch processing across tenants.
  - Preserve data correctness when concurrent batches touch the same device.
  - Keep database load bounded and observable.
- Non-Goals:
  - Changing device identity rules or DIRE resolution priority.
  - Modifying sync result chunking or gateway protocols.

## Decisions
- Decision: Add a dedicated Task.Supervisor for sync ingestion work.
  - Why: isolates ingestion tasks and provides a single place to control concurrency.
- Decision: Dispatch each sync results chunk into the task pool from StatusHandler.
  - Why: prevents GenServer mailbox backpressure from serializing chunks.
- Decision: Introduce a per-tenant ingestion queue with a short coalescing window.
  - Why: smooths bursty chunk delivery and reduces concurrent DB spikes while preserving tenant order.
- Decision: Use bounded parallelism inside SyncIngestor (Task.async_stream).
  - Why: keeps DB load stable while increasing throughput.
- Decision: Use insert_all upsert for device records.
  - Why: eliminates per-row update loops and removes race conditions between concurrent batches.

## Risks / Trade-offs
- Higher parallelism can increase database contention; use a conservative default and allow config overrides.
- Upsert semantics must avoid overwriting first_seen/created_time; only update mutable fields.

## Migration Plan
- No data migration required.
- Deploy with default concurrency tuned for local dev and allow config overrides for production.

## Open Questions
- Preferred default concurrency (suggest 4 or System.schedulers_online/2)?
