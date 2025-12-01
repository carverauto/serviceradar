## 1. Bootstrap AGE graph in CNPG

- [x] 1.1 Add migration/init script to `create_graph('serviceradar')` and enable AGE search_path for core/SRQL connections
- [x] 1.2 Define indexes/constraints for canonical IDs on Device, Service, Collector, Interface nodes and ensure idempotent creation
- [x] 1.3 Add ops/runbook steps for Docker Compose + demo k8s to verify AGE graph readiness
- [x] 1.4 Add AGE write credentials/config to DIRE/SRQL/core so they can emit Cypher writes

## 2. Graph schema and contracts

- [x] 2.1 Define node labels/properties for Device, Interface, Service (internal vs target), Collector (agent/poller), CheckerDefinition, Capability (snmp/otel/sysmon)
- [x] 2.2 Define edge types/properties (HOSTS_SERVICE, RUNS_CHECKER, TARGETS, HAS_INTERFACE, CONNECTS_TO, PROVIDES_CAPABILITY, REPORTED_BY)
- [x] 2.3 Document canonical ID format mapping (unified_device.canonical_device_id → Device.id, service_device_id → Service.id, agent/poller ids → Collector.id, interface fingerprint)
- [x] 2.4 Add AGE schema docs to `docs/docs/` (or `openspec/design.md`) for reference
- [x] 2.5 Map DIRE resolution outputs to graph nodes/edges so the graph stays aligned with unified_devices

## 3. Ingestion pipelines into AGE

- [x] 3.1 Wire core registry/device updates (via DIRE output) to `MERGE` Device + Capability edges (SNMP/OTEL/sysmon) without creating collector-host devices
- [x] 3.2 Emit Service nodes/edges for internal services (datasvc/sync/mapper/otel/zen) attached to their collector nodes instead of standalone devices
- [x] 3.3 Map checker results to TARGETS/RUNS_CHECKER edges from Service/CheckerDefinition → Device targets; ensure collector host metadata is ignored for node creation
- [x] 3.4 Ingest mapper interface discoveries as Interface nodes attached to Devices; add CONNECTS_TO edges between interfaces when topology is known; seed devices discovered via mapper through DIRE to reuse canonical IDs
- [x] 3.5 Provide backpressure/error handling so AGE failures do not block registry ingestion, with metrics + logs
- [x] 3.6 Add reconciliation/backfill from unified_devices + mapper discoveries to heal graph drift

## 4. API surfaces and queries

- [x] 4.1 Add API endpoint/DAO to fetch a device neighborhood (collector → service/checker → target → interfaces) from AGE
- [x] 4.2 Add filters to return only collector-owned services/checkers vs external targets
- [x] 4.3 Provide Cypher snippets or stored procedures for common queries (device summary, path to collector, service capability badges)
- [x] 4.4 Add a new SRQL entity `in:device_graph` that reads from AGE for inventory-like queries (neighborhood/relationships) instead of only `unified_devices`, returning structured JSON (collector-owned flags, capabilities, interfaces) from AGE Cypher rather than raw agtype
- [x] 4.5 Expose graph queries for AI copilots so responses draw from canonical relationships
- [x] 4.6 Add SRQL AGE bootstrap + fixtures in tests (graph_path, labels, sample neighborhood) and integration tests that validate the graph query contract and JSON shape

## 5. Web inventory integration

- [x] 5.1 Update inventory UI to show graph-derived badges (e.g., "collector service", "SNMP metrics") instead of duplicating devices
- [x] 5.2 Ensure entries like sync/mapper/zen health checks render as services on `docker-agent`/poller, not as separate devices named "agent"
- [x] 5.3 Add UI affordances to hide/filter collector-owned health checks while keeping true targets visible
- [x] 5.4 Build hierarchical Device Inventory view (Device → services/collectors/child agents) and Network Discovery/Interfaces view (Device → interfaces) without listing interfaces as top-level devices
- [x] 5.5 Add a graph-based device detail view (ReactFlow) showing collectors, services, targets, and interfaces in a single neighborhood canvas with badges/links
- [x] 5.6 Make the default Device Inventory experience hierarchy-first in the table view: roll child services/agents under parents by default with SRQL link-outs to the underlying `in:device_graph` query (no card layout)
- [x] 5.7 Implement expandable poller rows that reveal agents/collector services as indented table rows (color-coded relationship rows), keeping collectors visible as first-class devices while suppressing agent/checker rows until expanded; preserve pagination/performance for large inventories (50k–5M devices)

## 6. Backfill, testing, and validation

- [x] 6.1 Add backfill/rebuild job to regenerate AGE graph from relational sources (device updates, mapper interfaces, checker history)
- [x] 6.2 Add unit/integration tests for graph ingestion and neighborhood queries (including collector-vs-target distinction)
- [x] 6.3 Document validation steps: run on docker-compose.mtls and confirm phantom checker devices do not reappear; verify SNMP target shows metrics badge
- [ ] 6.4 Validate mapper-seeded devices (seed router + neighbors) create correct Device/Interface/CONNECTS_TO relationships in the graph
- [ ] 6.5 Validate SRQL/graph queries back the UI without unified_devices joins

---

Progress notes:
- Compose mTLS stack rebuilt on APP_TAG `sha-3c7fc58993090562980d9fa62aab7caeb4c8db19`; search_path corrected to `public, ag_catalog`, CNPG collation refreshed, and AGE cypher() params in the graph writer converted to stringified JSON for compatibility.
- Core/poller/agent/web running; data now lands in `public` (unified_devices=10, pollers=1, logs/traces populated). UI validation + AGE backfill still outstanding.
- AGE graph writer cypher calls reworked to use parameter maps (no format() dollar quoting); compose refreshed with APP_TAG `sha-d03721f47c5c7b4575da2a3f00c475bcfa0b0237` and services healthy.
- AGE neighborhood helper updated to drop graph_path, pin search_path to `ag_catalog,pg_catalog`, cast agtype via text/jsonb, and aggregate property maps to avoid null graph responses; re-applied migration to mTLS CNPG and verified age_device_neighborhood returns collectors/services/targets.
- Inventory UI now hides collector-owned service devices by default, surfaces them as collector services with badges/toggle + SRQL link-outs, and defaults graph cards to collector-owned view for service nodes.
- Device inventory graph cards now render child collectors for poller roots; network discovery view groups interfaces under their owning devices (no interface rows as top-level results) with per-device interface tables.
- ReactFlow-based device detail view + graph-centric inventory view still pending; will anchor on `in:device_graph` neighborhood responses and include interfaces in the canvas.
