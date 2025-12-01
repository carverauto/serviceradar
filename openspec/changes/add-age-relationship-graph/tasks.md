## 1. Bootstrap AGE graph in CNPG

- [ ] 1.1 Add migration/init script to `create_graph('serviceradar')` and enable AGE search_path for core/SRQL connections
- [ ] 1.2 Define indexes/constraints for canonical IDs on Device, Service, Collector, Interface nodes and ensure idempotent creation
- [ ] 1.3 Add ops/runbook steps for Docker Compose + demo k8s to verify AGE graph readiness
- [ ] 1.4 Add AGE write credentials/config to DIRE/SRQL/core so they can emit Cypher writes

## 2. Graph schema and contracts

- [ ] 2.1 Define node labels/properties for Device, Interface, Service (internal vs target), Collector (agent/poller), CheckerDefinition, Capability (snmp/otel/sysmon)
- [ ] 2.2 Define edge types/properties (HOSTS_SERVICE, RUNS_CHECKER, TARGETS, HAS_INTERFACE, CONNECTS_TO, PROVIDES_CAPABILITY, REPORTED_BY)
- [ ] 2.3 Document canonical ID format mapping (unified_device.canonical_device_id → Device.id, service_device_id → Service.id, agent/poller ids → Collector.id, interface fingerprint)
- [ ] 2.4 Add AGE schema docs to `docs/docs/` (or `openspec/design.md`) for reference
- [ ] 2.5 Map DIRE resolution outputs to graph nodes/edges so the graph stays aligned with unified_devices

## 3. Ingestion pipelines into AGE

- [ ] 3.1 Wire core registry/device updates (via DIRE output) to `MERGE` Device + Capability edges (SNMP/OTEL/sysmon) without creating collector-host devices
- [ ] 3.2 Emit Service nodes/edges for internal services (datasvc/sync/mapper/otel/zen) attached to their collector nodes instead of standalone devices
- [ ] 3.3 Map checker results to TARGETS edges from Service/CheckerDefinition → Device targets; ensure collector host metadata is ignored for node creation
- [ ] 3.4 Ingest mapper interface discoveries as Interface nodes attached to Devices; add CONNECTS_TO edges between interfaces when topology is known; seed devices discovered via mapper through DIRE to reuse canonical IDs
- [ ] 3.5 Provide backpressure/error handling so AGE failures do not block registry ingestion, with metrics + logs
- [ ] 3.6 Add reconciliation/backfill from unified_devices + mapper discoveries to heal graph drift

## 4. API surfaces and queries

- [ ] 4.1 Add API endpoint/DAO to fetch a device neighborhood (collector → service/checker → target → interfaces) from AGE
- [ ] 4.2 Add filters to return only collector-owned services/checkers vs external targets
- [ ] 4.3 Provide Cypher snippets or stored procedures for common queries (device summary, path to collector, service capability badges)
- [ ] 4.4 Update SRQL planner to read from graph for inventory-like queries (neighborhood/relationships) instead of only `unified_devices`
- [ ] 4.5 Expose graph queries for AI copilots so responses draw from canonical relationships

## 5. Web inventory integration

- [ ] 5.1 Update inventory UI to show graph-derived badges (e.g., "collector service", "SNMP metrics") instead of duplicating devices
- [ ] 5.2 Ensure entries like sync/mapper/zen health checks render as services on `docker-agent`/poller, not as separate devices named "agent"
- [ ] 5.3 Add UI affordances to hide/filter collector-owned health checks while keeping true targets visible
- [ ] 5.4 Build hierarchical Device Inventory view (Device → services/collectors/child agents) and Network Discovery/Interfaces view (Device → interfaces) without listing interfaces as top-level devices

## 6. Backfill, testing, and validation

- [ ] 6.1 Add backfill/rebuild job to regenerate AGE graph from relational sources (device updates, mapper interfaces, checker history)
- [ ] 6.2 Add unit/integration tests for graph ingestion and neighborhood queries (including collector-vs-target distinction)
- [ ] 6.3 Document validation steps: run on docker-compose.mtls and confirm phantom checker devices do not reappear; verify SNMP target shows metrics badge
- [ ] 6.4 Validate mapper-seeded devices (seed router + neighbors) create correct Device/Interface/CONNECTS_TO relationships in the graph
- [ ] 6.5 Validate SRQL/graph queries back the UI without unified_devices joins
