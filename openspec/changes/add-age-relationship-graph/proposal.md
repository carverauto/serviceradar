# Change: Apache AGE Relationship Graph for Devices and Services

## Why
Checker hosts are still leaking into inventory as phantom devices (e.g., sysmon/mapper/zen health probes appearing as `agent` devices) even after the fix-checker-device-identity rollout. Mapper discoveries and DIRE outputs are not represented as relationships, so interfaces and neighbors cannot be navigated cleanly. We need an explicit relationship model to keep collector-owned services/checkers attached to their agents, surface SNMP targets with their interfaces, drive relationship-aware inventory badges/topology views, and give the UI/AI clear labels instead of misclassified devices. Apache AGE is already bundled in our CNPG images; we should start using it to persist the device/service/collector graph.

## What Changes
- Bootstrap an `age` graph (`serviceradar`) in CNPG with node/edge types for devices, interfaces, services (internal + target), collectors, and checker definitions, plus indexes on canonical IDs.
- Ingest registry updates (agents/pollers/services), mapper discoveries, checker results, and sync/DIRE device updates into AGE, merging on canonical IDs and ensuring collector host metadata does NOT create new device nodes.
- Store relationships for health checks and metrics capabilities (e.g., SNMP/OTEL/sysmon) so inventory can label nodes like "sync (collector service)" or show that a router has SNMP metrics available.
- Expose graph query surfaces for the UI/API/SRQL to fetch a device’s neighborhood (collector → service/checker → target → interfaces) and render badges instead of duplicating devices, including a dedicated SRQL entity `in:device_graph`.
- Add a rebuild/backfill job to regenerate the graph from relational tables (unified_devices, registry, mapper) and emit observability around graph drift or ingestion failures.
- Keep the Device Inventory table flat while using graph relationships for badges/filters; show relationships in device detail/graph canvases and a Network Discovery/Interfaces view without polluting the device list with interfaces.
- Make the graph the source for AI/device reasoning so answers use canonical IDs/relationships instead of flat unified_devices queries.

## Impact
- Affected specs: `device-relationship-graph` (new), `cnpg` (AGE graph initialization), `device-identity-reconciliation` (collector-vs-target handling), `web` inventory visualization
- Affected code: CNPG migrations/bootstrap, core registry ingestion, mapper interface pipeline, checker ingestion, DIRE output fanout to AGE, SRQL/graph queries, web inventory APIs/components, AI query wiring

## Scope updates (2025-12-01)
- Drop the hierarchy-first table in the main Device Inventory; return to the flat inventory view and surface relationships via badges plus detail/graph views (hierarchy stays out of the table for now).
- Network neighborhood canvas: large sweep/Armis/NetBox imports (50k+ nodes) require an alternative visualization or aggregation strategy; leaving this as an open item.

## Scope updates (2025-12-03)
- Replace the ReactFlow neighborhood canvas with a D3 hierarchy/cluster-based dendrogram that auto-lays out collectors → services/checkers → targets/interfaces so edges always render and the graph stays compact on the device detail page.
- Add a large-neighborhood fallback that clusters sweep/Armis-scale results (e.g., 50k+ devices) by CIDR using a pack layout instead of drawing every edge to avoid blowing up the device detail graph.
