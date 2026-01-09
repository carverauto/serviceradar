# Change: Improve sync ingestion throughput

## Why
Sync result ingestion serializes chunk processing and performs per-record updates, which makes 50k device syncs take tens of minutes and blocks subsequent chunks.

## What Changes
- Run sync result ingestion asynchronously so later chunks are not blocked by earlier ones.
- Process sync batches concurrently with a bounded concurrency cap to protect CNPG.
- Replace per-row device updates with conflict-safe bulk upserts to avoid lost updates under parallel ingestion.
- Fix audit event inserts to use UUID encodings accepted by CNPG (bug fix).

## Impact
- Affected specs: device-identity-reconciliation, device-inventory
- Affected code: elixir/serviceradar_core/lib/serviceradar/status_handler.ex, elixir/serviceradar_core/lib/serviceradar/inventory/sync_ingestor.ex, elixir/serviceradar_core/lib/serviceradar/events/audit_writer.ex, elixir/serviceradar_core/lib/serviceradar/application.ex
