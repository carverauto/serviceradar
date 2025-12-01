# AGE graph readiness checks

Use this runbook to confirm the Apache AGE graph (`serviceradar`) is present and usable after bootstrap. The checks cover the mTLS Docker Compose stack and the demo Kubernetes namespace.

## Docker Compose (docker-compose.mtls.yml)
- Ensure CNPG is up: `docker compose -f docker-compose.mtls.yml ps cnpg`
- Verify graph defaults:
  - `docker compose -f docker-compose.mtls.yml exec cnpg psql -U ${CNPG_USERNAME:-serviceradar} -d ${CNPG_DATABASE:-serviceradar} -c "SHOW search_path; SHOW graph_path;"`
  - Expected: `search_path` includes `ag_catalog,"$user",public` and `graph_path` is `serviceradar`.
- Confirm AGE is ready:
  - `docker compose -f docker-compose.mtls.yml exec cnpg psql -U ${CNPG_USERNAME:-serviceradar} -d ${CNPG_DATABASE:-serviceradar} -c "SELECT extname FROM pg_extension WHERE extname='age';"`
  - `docker compose -f docker-compose.mtls.yml exec cnpg psql -U ${CNPG_USERNAME:-serviceradar} -d ${CNPG_DATABASE:-serviceradar} -c "SELECT name FROM ag_catalog.ag_graph WHERE name='serviceradar';"`
  - `docker compose -f docker-compose.mtls.yml exec cnpg psql -U ${CNPG_USERNAME:-serviceradar} -d ${CNPG_DATABASE:-serviceradar} -c "SELECT name, kind FROM ag_catalog.ag_label WHERE graph=(SELECT oid FROM ag_catalog.ag_graph WHERE name='serviceradar') ORDER BY kind, name;"`
  - `docker compose -f docker-compose.mtls.yml exec cnpg psql -U ${CNPG_USERNAME:-serviceradar} -d ${CNPG_DATABASE:-serviceradar} -c "SELECT * FROM ag_catalog.cypher('serviceradar', 'RETURN 1') AS (result agtype);"`
- If any checks fail, rerun migrations (core connects with AGE defaults) or manually create the graph: `CREATE EXTENSION IF NOT EXISTS age; SELECT ag_catalog.create_graph('serviceradar');`.

## Demo Kubernetes (namespace demo)
- Wait for CNPG to be ready: `kubectl -n demo wait --for=condition=Ready pod -l cnpg.io/cluster=cnpg --timeout=300s`.
- Use the tools pod profile (defaults to the `telemetry` database):
  - `kubectl -n demo exec deploy/serviceradar-tools -- cnpg-info`
  - `kubectl -n demo exec deploy/serviceradar-tools -- cnpg-sql "SHOW search_path; SHOW graph_path;"`
  - `kubectl -n demo exec deploy/serviceradar-tools -- cnpg-sql "SELECT extname FROM pg_extension WHERE extname='age';"`
  - `kubectl -n demo exec deploy/serviceradar-tools -- cnpg-sql "SELECT name FROM ag_catalog.ag_graph WHERE name='serviceradar';"`
  - `kubectl -n demo exec deploy/serviceradar-tools -- cnpg-sql "SELECT name, kind FROM ag_catalog.ag_label WHERE graph=(SELECT oid FROM ag_catalog.ag_graph WHERE name='serviceradar') ORDER BY kind, name;"`
  - `kubectl -n demo exec deploy/serviceradar-tools -- cnpg-sql "SELECT * FROM ag_catalog.cypher('serviceradar', 'RETURN 1') AS (result agtype);"`
- If the graph is missing, re-run migrations from the tools pod or issue the manual `CREATE EXTENSION` + `create_graph('serviceradar')` statements above (safe to rerun).

## Rebuild/backfill the AGE graph
- Use the new backfill utility to rehydrate nodes/edges from CNPG tables:
  - Local repo: `go run ./cmd/tools/age-backfill --host ${CNPG_HOST:-localhost} --database ${CNPG_DATABASE:-serviceradar} --username ${CNPG_USERNAME:-serviceradar} --password ${CNPG_PASSWORD:-serviceradar}`
  - Bazel: `bazel run //cmd/tools/age-backfill -- --host <host> --database <db> --username <user> --password <pass>`
  - Demo k8s: `kubectl -n demo exec deploy/serviceradar-tools -- age-backfill`
- The job reads `unified_devices`, `discovered_interfaces`, and `topology_discovery_events` and writes MERGE batches via AGE cypher.
- Ensure `CNPG_*` env (host, port, database, username, password/secret, sslmode) are available in the execution environment.

## Validate collector-owned vs target nodes (phantom device guard)
Use the same `psql` entrypoint above (`docker compose ... exec cnpg psql ... -c "<SQL>"` or `kubectl -n demo exec deploy/serviceradar-tools -- cnpg-sql "<SQL>"`).
- Confirm no collector service IDs leaked into `Device` nodes (expect zero rows):
  ```sql
  SELECT properties->>'id' AS collector_device_node
  FROM serviceradar."Device"
  WHERE properties->>'id' LIKE 'serviceradar:agent:%'
     OR properties->>'id' LIKE 'serviceradar:poller:%';
  ```
- Pick a real device ID (non-`serviceradar:`) and verify collector-owned services are returned without creating a device node for the collector host:
  ```sql
  SELECT properties->>'id' FROM serviceradar."Device" WHERE properties->>'id' NOT LIKE 'serviceradar:%' LIMIT 1;
  SELECT jsonb_pretty(public.age_device_neighborhood('<device_id>', true, false));
  ```
  The `services.collector_owned` flag should be `true`, and no collector IP should appear as a `Device`.
- Validate SNMP capability badges are attached to targets, not collector hosts:
  ```sql
  SELECT d.properties->>'id' AS device_id
  FROM serviceradar."Device" d
  JOIN serviceradar."PROVIDES_CAPABILITY" pc ON pc.start_id = d.id
  JOIN serviceradar."Capability" cap ON cap.id = pc.end_id
  WHERE cap.properties->>'type' = 'snmp'
  LIMIT 5;
  -- Pick one device_id and ensure the neighborhood shows the snmp badge
  SELECT jsonb_pretty(public.age_device_neighborhood('<device_id>', false, false));
  ```
- API spot-check (core or web): `curl -s -H "X-API-Key: $API_KEY" "http://<core-host>:8090/api/devices/<device_id>/graph?collector_owned=true&include_topology=false"` should return the same structure with `collector_owned:true` on service/checker nodes and `device_capabilities` containing `snmp` for SNMP targets.

## Validate mapper interfaces and topology
- Identify mapper-seeded devices to inspect:
  ```sql
  SELECT DISTINCT device_id FROM discovered_interfaces ORDER BY updated_at DESC LIMIT 5;
  ```
- For a chosen device ID, confirm interfaces are present and connected:
  ```sql
  SELECT iface.properties->>'id' AS interface_id
  FROM serviceradar."Interface" iface
  JOIN serviceradar."HAS_INTERFACE" hi ON hi.end_id = iface.id
  JOIN serviceradar."Device" d ON d.id = hi.start_id
  WHERE d.properties->>'id' = '<device_id>';

  SELECT src.properties->>'id' AS from_iface, dst.properties->>'id' AS to_iface
  FROM serviceradar."CONNECTS_TO" link
  JOIN serviceradar."Interface" src ON src.id = link.start_id
  JOIN serviceradar."Interface" dst ON dst.id = link.end_id
  WHERE src.properties->>'id' LIKE '<device_id>/%'
  LIMIT 10;
  ```
- The stored helper should mirror those edges: `SELECT jsonb_pretty(public.age_device_neighborhood('<device_id>', false, true));` will include `interfaces` and `peer_interfaces` when mapper topology edges exist.
