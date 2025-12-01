# Change: Apache AGE Relationship Graph for Devices and Services

## Why
Checker hosts are still leaking into inventory as phantom devices (e.g., sysmon/mapper/zen health probes appearing as `agent` devices) even after the fix-checker-device-identity rollout. Mapper discoveries and DIRE outputs are not represented as relationships, so interfaces and neighbors cannot be navigated cleanly. We need an explicit relationship model to keep collector-owned services/checkers attached to their agents, surface SNMP targets with their interfaces, drive hierarchical inventory views, and give the UI/AI clear labels instead of misclassified devices. Apache AGE is already bundled in our CNPG images; we should start using it to persist the device/service/collector graph.

## What Changes
- Bootstrap an `age` graph (`serviceradar`) in CNPG with node/edge types for devices, interfaces, services (internal + target), collectors, and checker definitions, plus indexes on canonical IDs.
- Ingest registry updates (agents/pollers/services), mapper discoveries, checker results, and sync/DIRE device updates into AGE, merging on canonical IDs and ensuring collector host metadata does NOT create new device nodes.
- Store relationships for health checks and metrics capabilities (e.g., SNMP/OTEL/sysmon) so inventory can label nodes like "sync (collector service)" or show that a router has SNMP metrics available.
- Expose graph query surfaces for the UI/API/SRQL to fetch a device’s neighborhood (collector → service/checker → target → interfaces) and render badges instead of duplicating devices.
- Add a rebuild/backfill job to regenerate the graph from relational tables (unified_devices, registry, mapper) and emit observability around graph drift or ingestion failures.
- Provide hierarchical views: Device Inventory (device → services/collectors/child agents) and Network Discovery/Interfaces (device → interfaces) without polluting the device list with interfaces.
- Make the graph the source for AI/device reasoning so answers use canonical IDs/relationships instead of flat unified_devices queries.

## Impact
- Affected specs: `device-relationship-graph` (new), `cnpg` (AGE graph initialization), `device-identity-reconciliation` (collector-vs-target handling), `web` inventory visualization
- Affected code: CNPG migrations/bootstrap, core registry ingestion, mapper interface pipeline, checker ingestion, DIRE output fanout to AGE, SRQL/graph queries, web inventory APIs/components, AI query wiring
