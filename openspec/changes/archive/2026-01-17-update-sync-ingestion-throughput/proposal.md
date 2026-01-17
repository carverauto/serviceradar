# Change: Improve sync ingestion throughput

## Why
Sync result ingestion still spikes the database under bursty chunk delivery and lacks tenant-aware backpressure, which makes large device syncs slower and risks queue timeouts as tenant volume grows.

## What Changes
- Run sync result ingestion asynchronously so later chunks are not blocked by earlier ones.
- Buffer sync chunks per tenant and coalesce bursts into a single ingest window to smooth write load.
- Process sync batches with bounded concurrency across tenants to protect CNPG.
- Replace per-row device updates with conflict-safe bulk upserts to avoid lost updates under parallel ingestion.
- Fix audit event inserts to use UUID encodings accepted by CNPG (bug fix).

## Impact
- Affected specs: device-identity-reconciliation, device-inventory
- Affected code: elixir/serviceradar_core/lib/serviceradar/status_handler.ex, elixir/serviceradar_core/lib/serviceradar/inventory/sync_ingestor.ex, elixir/serviceradar_core/lib/serviceradar/events/audit_writer.ex, elixir/serviceradar_core/lib/serviceradar/application.ex
