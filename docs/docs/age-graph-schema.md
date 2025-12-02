# AGE graph schema and access

This document captures the canonical AGE graph schema (`serviceradar`), ID formats, and the access expectations for ServiceRadar services (core, SRQL, DIRE).

## Graph and access defaults
- Graph name: `serviceradar`
- Extensions: `age` (plus `timescaledb`)
- Database defaults: `search_path=ag_catalog,"$user",public`; `graph_path` may be absent in the current CNPG build, so Cypher calls must always pass the graph name explicitly.
- Role grants (migration `00000000000012_age_graph_bootstrap.up.sql`):
  - `GRANT USAGE ON SCHEMA ag_catalog` and `EXECUTE` on its functions to the `serviceradar` role.
  - `GRANT USAGE` on graph schema `serviceradar`, `ALL PRIVILEGES` on its tables, and default privileges for future tables to the `serviceradar` role.

## Node labels and properties
- `Device`
  - Required: `id` (canonical_device_id)
  - Optional: `ip`, `hostname`
- `Collector` (agent or poller)
  - Required: `id` (`serviceradar:agent:<id>` or `serviceradar:poller:<id>`)
  - Optional: `type` (agent|poller), `ip`, `hostname`
- `Service` (internal services and checker service devices)
  - Required: `id` (`service_device_id`), `type` (e.g., sync, mapper, otel, checker)
  - Optional: `ip`, `hostname`, `collector_id` (host owner for convenience)
- `Interface`
  - Required: `id` (`<device_id>/<ifname>` or `<device_id>/ifindex:<n>`), `device_id`
  - Optional: `name`, `descr`, `alias`, `mac`, `ip_addresses`, `ifindex`
- `Capability`
  - Required: `type` (e.g., `snmp`, `otel`, `sysmon`, `healthcheck`, `checker`)
- `CheckerDefinition` (reserved for future checker metadata)
  - Required: `id`; optional: `name`, `version`

## Edge labels and semantics
- `HOSTS_SERVICE` (Collector → Service): internal services running on a collector
- `RUNS_CHECKER` (Collector → Service/CheckerDefinition): collector executes a checker
- `TARGETS` (Service/CheckerDefinition → Device): checker or service target device; optional edge props: `checker_service`
- `HAS_INTERFACE` (Device → Interface): discovered interfaces
- `CONNECTS_TO` (Interface → Interface): topology links (mapper/LLDP/CDP); optional edge props: `source` (lldp/cdp/manual)
- `PROVIDES_CAPABILITY` (Service or Device → Capability): metrics/health capabilities; optional edge props: `status`
- `REPORTED_BY` (Device → Collector): provenance for sightings/updates; optional edge props: `source` (dire/mapper/checker)

## Canonical ID mapping
- Devices: `unified_devices.canonical_device_id` → `Device.id`
- Collectors: `serviceradar:agent:<id>` / `serviceradar:poller:<id>` → `Collector.id`
- Services (internal + checker): `service_device_id` (e.g., `serviceradar:service:ssh@agent-1`, `serviceradar:checker:sysmon@agent-1`) → `Service.id`
- Interfaces: `<device_id>/<ifname>` (fallback `ifindex:<n>`) → `Interface.id`
  - Direction: mapper seeds/neighbor discoveries must flow through DIRE to obtain the canonical device ID before interface/link creation.

## Ingestion sources
- DIRE / registry: emits Device nodes, Collector nodes, Service nodes, `REPORTED_BY`, `HOSTS_SERVICE`, `RUNS_CHECKER`, `TARGETS`, and `PROVIDES_CAPABILITY` edges.
- Mapper: emits Interface nodes (`HAS_INTERFACE`) and topology (`CONNECTS_TO`).
- Checkers: emit RUNS_CHECKER + TARGETS edges without promoting collector host IPs to Device nodes.

### DIRE → AGE mapping (required fields)
- `canonical_device_id` → `Device.id`; `ip`, `hostname` applied as properties.
- `agent_id`/`poller_id` → `Collector.id` (`serviceradar:agent:<id>` / `serviceradar:poller:<id>`) + `REPORTED_BY` from Device → Collector.
- `service_device_id` (internal services + checkers) → `Service.id`; `service_type` drives `Service.type`; `collector_id` derived from host agent/poller to create `HOSTS_SERVICE` (and `RUNS_CHECKER` when type = checker).
- Checker-sourced updates: `checker_service` + agent/poller IDs produce a `Service` node (checker) with `TARGETS` → Device; collector host IPs are not promoted to Device nodes.
- Mapper/DIRE-resolved interfaces: use DIRE-resolved `device_id` to form `Interface.id = <device_id>/<ifname or ifindex>` and add `HAS_INTERFACE`; topology events add `CONNECTS_TO` between interface IDs derived from DIRE-managed device IDs.

## Query guidance
- Always pass the graph name in `cypher` calls: `cypher('serviceradar', $$ ... $$)`.
- Keep `search_path` including `ag_catalog` to expose the `cypher` function and `agtype`.

## Common queries
- Device neighborhood (collector-owned filter + optional topology) via stored procedure:
  ```sql
  SELECT public.age_device_neighborhood('device-alpha', true, false);
  ```
- Service → collector → target path with capability badges:
  ```sql
  SELECT jsonb_pretty(result)
  FROM ag_catalog.cypher(
      'serviceradar',
      $$MATCH (c:Collector {id:'serviceradar:agent:agent-1'})-[:HOSTS_SERVICE]->(svc:Service {id:'serviceradar:service:ssh@agent-1'})-[:TARGETS]->(t:Device)
        OPTIONAL MATCH (t)-[:PROVIDES_CAPABILITY]->(cap:Capability)
        RETURN jsonb_build_object('collector', c, 'service', svc, 'target', t, 'capabilities', collect(cap))$$
  ) AS (result ag_catalog.agtype);
  ```
