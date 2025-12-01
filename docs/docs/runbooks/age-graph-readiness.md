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
