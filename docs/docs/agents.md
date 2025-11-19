---
sidebar_position: 12
title: Agents & Demo Operations
---

# Agents & Demo Operations

This runbook captures the operational steps we used while debugging the canonical device pipeline in the demo cluster. It focuses on the pieces that interact with the "agent" side of the world (faker → sync → core) and the backing CNPG/Timescale telemetry database.

## Rebuilding the SPIRE CNPG cluster (TimescaleDB + AGE)

SPIRE now depends on the `ghcr.io/carverauto/serviceradar-cnpg` image so the
in-cluster CNPG deployment always exposes PostgreSQL 16.6 with the prebuilt
TimescaleDB + Apache AGE extensions. Use this flow whenever you need to wipe or
upgrade the database:

1. **Delete the old cluster**

   ```bash
   kubectl delete cluster cnpg -n demo
   ```

   Wait for all `cnpg-*` pods to disappear before continuing.

2. **Apply the refreshed manifests**

   ```bash
   kubectl apply -k k8s/demo/base/spire
   ```

   Confirm the pods point at the custom image:

   ```bash
   kubectl get pods -n demo -l cnpg.io/cluster=cnpg \
     -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].image}{"\n"}{end}'
   ```

3. **Verify the extensions**

   ```bash
   kubectl exec -n demo cnpg-0 -- \
     psql -U spire -d spire \
       -c "SELECT extname FROM pg_extension WHERE extname IN ('timescaledb','age');"
   ```

   Both rows must exist; rerun `CREATE EXTENSION` if either entry is missing.

4. **Smoke test SPIRE**

   ```bash
   kubectl rollout status statefulset/spire-server -n demo
   kubectl logs statefulset/spire-server -n demo -c controller-manager --tail=50
   ```

   The controller manager should immediately reconcile the `ClusterSPIFFEID`
   objects. Finish with `scripts/test.sh` (or another `spire-agent api fetch`)
   to prove workloads can still mint SVIDs.

## Running CNPG telemetry migrations

The Timescale schema (`pkg/db/cnpg/migrations/*.sql`) now ships inside the
`cmd/tools/cnpg-migrate` helper, so you no longer need to exec into pods or copy
SQL files around to hydrate a fresh telemetry database. Configure the connection
via environment variables and call either `make cnpg-migrate` or the Bazel
binary:

- `CNPG_HOST`/`CNPG_PORT` – target endpoint (defaults to `127.0.0.1:5432`)
- `CNPG_DATABASE` – telemetry database name (`telemetry` in the demo cluster)
- `CNPG_USERNAME`/`CNPG_PASSWORD` or `CNPG_PASSWORD_FILE`
- Optional TLS knobs: `CNPG_CERT_DIR`, `CNPG_CA_FILE`, `CNPG_CERT_FILE`,
  `CNPG_KEY_FILE`, and `CNPG_SSLMODE`
- Advanced tuning: `CNPG_APP_NAME`, `CNPG_MAX_CONNS`, `CNPG_MIN_CONNS`,
  `CNPG_STATEMENT_TIMEOUT`, `CNPG_HEALTH_CHECK_PERIOD`, or
  repeated `--runtime-param key=value` flags (pass them via
  `make cnpg-migrate ARGS="--runtime-param work_mem=64MB"`).

### Demo quickstart

```bash
# 1) Port-forward to the RW service
kubectl port-forward -n demo svc/cnpg-rw 55432:5432 >/tmp/cnpg-forward.log &

# 2) Export connection details (superuser secret works for schema changes)
export CNPG_HOST=127.0.0.1
export CNPG_PORT=55432
export CNPG_DATABASE=telemetry
export CNPG_USERNAME=postgres
export CNPG_PASSWORD="$(kubectl get secret -n demo cnpg-superuser -o jsonpath='{.data.password}' | base64 -d)"

# 3) Run the migrations (same binary behind `bazel run //cmd/tools/cnpg-migrate:cnpg-migrate`)
make cnpg-migrate
```

The tool logs each migration file before executing it and exits non-zero if any
statement fails, making it safe to run in CI/CD or during demo refreshes.

### Running migrations from `serviceradar-tools`

The `serviceradar-tools` image now bundles `cnpg-migrate`, so you can run the
schema updates entirely inside the cluster—useful for `demo-staging` rehearsals:

```bash
# Use Bazel to build + push the updated toolbox image before rolling:
bazel run --config=remote //docker/images:tools_image_amd64_push

# Update k8s/demo/staging/kustomization.yaml so the `images:` stanza
# points at the new sha tag from the push output, for example:
#   - name: ghcr.io/carverauto/serviceradar-tools
#     newTag: sha-$(git rev-parse HEAD)

# After redeploying the toolbox, exec into it and run migrations:
kubectl exec -n demo-staging deploy/serviceradar-tools -- \
  env CNPG_HOST=cnpg-rw.demo-staging.svc.cluster.local \
      CNPG_DATABASE=telemetry \
      CNPG_USERNAME=postgres \
      CNPG_PASSWORD="$(kubectl get secret -n demo-staging cnpg-superuser -o jsonpath='{.data.password}' | base64 -d)" \
      cnpg-migrate --app-name serviceradar-tools
```

Adjust the credentials/flags if you run against a read/write replica or use a
service-specific role. The command prints each migration it applies so you can
capture the log alongside other staging validation artifacts.

## Enabling TimescaleDB + AGE in the telemetry database

The CNPG image already bundles both extensions; you just need to enable them in
every database that stores ServiceRadar data. Run the following SQL after
connecting to the telemetry database (adjust the username if you minted a
service-specific role):

```sql
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS age;
SELECT extname FROM pg_extension WHERE extname IN ('timescaledb','age') ORDER BY 1;
```

### Demo verification

```bash
kubectl exec -n demo cnpg-0 -- \
  env PGPASSWORD="$(kubectl get secret -n demo cnpg-superuser -o jsonpath='{.data.password}' | base64 -d)" \
  psql -U postgres -d telemetry <<'SQL'
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS age;
SELECT extname FROM pg_extension WHERE extname IN ('timescaledb','age') ORDER BY 1;
SQL
```

Expected output:

```
  extname
-----------
 age
 timescaledb
(2 rows)
```

Repeat the same sequence in any non-demo cluster (Helm or customer deployments)
as part of the CNPG bootstrap so the telemetry schema and future AGE work share
the same extension surface.

## CNPG Smoke Test

Run `./scripts/cnpg-smoke.sh demo-staging` (or `make cnpg-smoke`) to exercise
the CNPG-backed API surface end-to-end. The helper:

- Logs into `serviceradar-core` and calls `/api/devices`, `/api/services/tree`,
  `/api/devices/metrics/status`, and the CNPG-backed metrics endpoints to prove
  the registry + metrics APIs stay reachable.
- Publishes a lifecycle CloudEvent to `events.devices.lifecycle` and polls the
  Timescale `events` table to confirm the db-event-writer path processed the
  payload (the script logs a warning instead of failing when the events table is
  empty, which is the norm in quiet demo-staging windows).
- Verifies the CNPG client wiring by running `SELECT COUNT(*) FROM events`
  directly against the database when a fresh CloudEvent is not observable.

Pass `NAMESPACE=<ns>` to target a different environment.

## Armis Faker Service

- Deployment: `serviceradar-faker` (`k8s/demo/base/serviceradar-faker.yaml`).
- Persistent state lives on the PVC `serviceradar-faker-data` and must be mounted at `/var/lib/serviceradar/faker`. The deployment now mounts the same volume at `/var/lib/serviceradar/faker` and `/data` so the generator can save `fake_armis_devices.json`.
- The faker always generates 50 000 devices and shuffles a percentage of their IPs every minute. Restarting the pod without the PVC used to create a fresh dataset—which is why the database ballooned past 150 k devices.

Useful checks:

```bash
kubectl get pods -n demo -l app=serviceradar-faker
kubectl exec -n demo deploy/serviceradar-faker -- ls /var/lib/serviceradar/faker
```

## Resetting the Device Pipeline

This clears the CNPG-backed telemetry tables and repopulates them with a fresh discovery crawl from the faker service.

1. **Quiesce sync** – stop new writes while we clear the tables:

   ```bash
   kubectl scale deployment/serviceradar-sync -n demo --replicas=0
   ```

2. **Flush the telemetry tables** – use the toolbox pod’s `cnpg-sql` helper so credentials and TLS bundles are wired automatically:

   ```bash
   kubectl exec -n demo deploy/serviceradar-tools -- \
     cnpg-sql <<'SQL'
   TRUNCATE TABLE device_updates;
   TRUNCATE TABLE unified_devices;
   TRUNCATE TABLE sweep_host_states;
   TRUNCATE TABLE discovered_interfaces;
   TRUNCATE TABLE topology_discovery_events;
   SQL
   ```

   Add or remove tables depending on what needs to be rebuilt (for example, include `timeseries_metrics` if you also want to clear historical CPU samples). The `cnpg-sql` wrapper exports every statement before running it so you can audit the destructive step in the pod logs.

3. **Refresh aggregates (optional)** – the metrics dashboards rely on `device_metrics_summary_cagg`. Recompute it once the tables are empty so new inserts are visible immediately:

   ```bash
   kubectl exec -n demo deploy/serviceradar-tools -- \
     cnpg-sql "CALL refresh_continuous_aggregate('device_metrics_summary_cagg', NULL, NULL);"
   ```

4. **Verify counts** – the faker dataset normally lands between 50–55k devices. Spot-check the tables directly so you can compare them with `/api/stats` later:

   ```bash
   kubectl exec -n demo deploy/serviceradar-tools -- \
     cnpg-sql <<'SQL'
   SELECT COUNT(*) AS device_rows FROM unified_devices;
   SELECT COUNT(*) AS update_rows FROM device_updates;
   SELECT COUNT(*) AS sweep_rows FROM sweep_host_states;
   SQL
   ```

5. **Resume discovery** – start the sync pipeline again:

   ```bash
   kubectl scale deployment/serviceradar-sync -n demo --replicas=1
   kubectl logs deployment/serviceradar-sync -n demo --tail 50
   ```

Once the sync pod reports “Completed streaming results”, poll `/api/stats` and the `/api/devices` endpoints to confirm the registry reflects the rebuilt CNPG rows.

## Monitoring Non-Canonical Sweep Data

- The core stats aggregator now publishes OTEL gauges under `serviceradar.core.device_stats` (`core_device_stats_skipped_non_canonical`, `core_device_stats_raw_records`, etc.). Point your collector at those gauges to alert when `skipped_non_canonical` climbs above zero.
- Collector capability writes now increment the OTEL counter `serviceradar_core_capability_events_total`. Alert on drops in `sum(rate(serviceradar_core_capability_events_total[5m]))` to make sure pollers continue reporting, and break the series down by the `capability`, `service_type`, and `recorded_by` labels when investigating gaps.
- Webhook integrations receive a `Non-canonical devices filtered from stats` warning the moment the skip counter increases. The payload includes `raw_records`, `processed_records`, the total filtered count, and the timestamp of the snapshot that triggered the alert.
- The analytics dashboard’s “Total Devices” card now shows the raw/processed breakdown plus a yellow callout whenever any skips occur. When investigating, open the browser console and inspect `window.__SERVICERADAR_DEVICE_COUNTER_DEBUG__` to review the last 25 `/api/stats` samples and headers.
- For ad-hoc validation, hit `/api/stats` directly; the `X-Serviceradar-Stats-*` headers mirror the numbers the alert uses (`X-Serviceradar-Stats-Skipped-Non-Canonical`, `X-Serviceradar-Stats-Skipped-Service-Components`, etc.).

## KV Configuration Checks

- The `serviceradar-tools` pod already bundles the `nats-kv` helper. Exec into the pod and list expected entries before debugging the Admin UI:

  ```bash
  kubectl exec -n demo deploy/serviceradar-tools -- nats-kv ls config
  kubectl exec -n demo deploy/serviceradar-tools -- nats-kv get config/core.json
  kubectl exec -n demo deploy/serviceradar-tools -- nats-kv get config/flowgger.toml
  ```

### Descriptor metadata health

1. Hit the admin metadata endpoint before assuming the UI is missing a form:

   ```bash
   curl -sS -H "Authorization: Bearer ${TOKEN}" \
     https://<core-host>/api/admin/config | jq '.[].service_type'
   ```

   Every service shown in the UI now comes directly from this payload. If a node is greyed out, confirm the descriptor exists here and that it advertises the right `scope`/`kv_key_template`.
2. Fetch the concrete config and metadata in the same session to prove KV state is present:

   ```bash
   curl -sS -H "Authorization: Bearer ${TOKEN}" \
     "https://<core-host>/api/admin/config/core" | jq '.metadata'
   ```

   A `404` at this step means the service never registered its template—usually because the workload did not start with `CONFIG_SOURCE=kv` or SPIFFE could not reach core.

### Watcher telemetry outside the demo cluster

- After rolling Helm or docker-compose, verify watchers register in the new process (not just the demo namespace):

  ```bash
  curl -sS -H "Authorization: Bearer ${TOKEN}" \
    https://<core-host>/api/admin/config/watchers | jq '.[] | {service, kv_key, status}'
  ```

  The table should include every global service plus any agent checkers that have reported in. Use the same call when a customer cluster reports “stale config” so you can immediately see if the watcher stopped.
- The Admin UI’s Watcher Telemetry panel is just a thin wrapper around the same endpoint. Keep it pinned while other environments roll so you can capture a screenshot proving the watchers stayed registered.

### Expected KV keys

- Global defaults must exist even if no devices are configured yet. Spot check the following whenever `/api/admin/config/*` starts returning `404`s:

  ```
  config/core.json
  config/sync.json
  config/poller.json
  config/agent.json
  config/flowgger.toml
  config/otel.toml
  config/db-event-writer.json
  config/zen-consumer.json
  ```
- Agent checkers follow `agents/<agent_id>/checkers/<service>/<service>.json`. When the UI requests an agent-scoped service it now always passes the descriptor metadata—if the API still returns `404`, exec into `serviceradar-tools` and confirm the key exists with `nats-kv get`.

- All Rust collectors now link the shared bootstrap library and pull KV at boot. If you need to rehydrate configs manually, exec into the pod and write the baked template back to disk:

  ```bash
  kubectl exec -n demo deploy/serviceradar-flowgger -- \
    cp /etc/serviceradar/templates/flowgger.toml /etc/serviceradar/flowgger.toml
  ```

  The service will reseed KV on next start; no separate `config-sync` sidecar is required.
- Hot reload is unified across OTEL, flowgger, trapd, and zen: when `CONFIG_SOURCE=kv`, each binary calls `config_bootstrap::watch()` and relies on the shared `RestartHandle` helper. Any `nats-kv put config/<service>` will log `KV update detected; restarting process to apply new config`, spawn a fresh process, and exit the old one so supervisors/container runtimes apply the overlay. Set `CONFIG_SOURCE=file` (or the service-specific `*_SEED_KV=false`) if you need to temporarily disable the watcher in lab environments.

## Device Registry Feature Flags

- Keep `features.require_device_registry` (in `serviceradar-config` → `core.json`) set to `true`. CNPG is now the only backing store, so the flag forces `/api/devices` and `/api/devices/{id}` to fail fast if the registry cache has not hydrated instead of serving stale in-memory data. Flip it to `false` only when you deliberately want core to start in read-only “maintenance” mode.
- Leave `features.use_device_search_planner` enabled alongside the web flag `NEXT_PUBLIC_FEATURE_DEVICE_SEARCH_PLANNER`. The planner keeps device search traffic on the CNPG-backed registry path and only dispatches SRQL work when a query truly requires it, which prevents accidental OLAP scans from hammering Timescale.

### Post-Rollout Verification (demo)

Run these checks after flipping `require_device_registry` or deploying new core images:

1. **Registry hydration**  
   ```bash
   kubectl logs deployment/serviceradar-core -n demo --tail=100 | \
     rg "Device registry hydrated"
   ```
   Expect a log line with `device_count` matching the CNPG row count (`~50k` in demo).

2. **Auth + API sanity**  
   ```bash
   API_KEY=$(kubectl get secret serviceradar-secrets -n demo \
     -o jsonpath='{.data.api-key}' | base64 -d)
   ADMIN_PW=$(kubectl get secret serviceradar-secrets -n demo \
     -o jsonpath='{.data.admin-password}' | base64 -d)

   # login to obtain a token
   TOKEN=$(kubectl run login-smoke --rm -i --restart=Never -n demo \
     --image=curlimages/curl:8.9.1 -- \
     curl -sS -H "Content-Type: application/json" \
       -H "X-API-Key: ${API_KEY}" \
       -d "{\"username\":\"admin\",\"password\":\"${ADMIN_PW}\"}" \
       http://serviceradar-core:8090/auth/login | jq -r '.access_token')

   # fetch a device (should succeed with registry data)
   kubectl run devices-smoke --rm -i --restart=Never -n demo \
     --image=curlimages/curl:8.9.1 -- \
     curl -sS -H "Authorization: Bearer ${TOKEN}" \
       "http://serviceradar-core:8090/api/devices?limit=1"
   ```

3. **Stats headers**  
   ```bash
   kubectl run stats-smoke --rm -i --restart=Never -n demo \
     --image=curlimages/curl:8.9.1 -- \
     curl -sS -D - -H "Authorization: Bearer ${TOKEN}" \
       http://serviceradar-core:8090/api/stats | head
   ```
   Confirm `X-Serviceradar-Stats-Skipped-Non-Canonical: 0` and processed/raw counts are ~50k.

4. **Planner diagnostics**  
   ```bash
   kubectl run planner-smoke --rm -i --restart=Never -n demo \
     --image=curlimages/curl:8.9.1 -- \
     curl -sS -H "Authorization: Bearer ${TOKEN}" \
       -H "Content-Type: application/json" \
       -d '{"query":"in:devices","filters":{"search":"k8s"},"pagination":{"limit":5}}' \
       http://serviceradar-core:8090/api/devices/search | jq '.diagnostics'
   ```
   Expect `engine":"registry"` / `engine_reason":"query_supported"` and latency in the low ms.

### Registry Query Guidance

- Treat `/api/devices/search` as the front door for inventory queries. The planner reports `engine` + `engine_reason` for every request so you can confirm whether the CNPG-backed registry cache or SRQL served the response.
- The `/api/query` proxy now runs through the same planner. Registry-capable queries (for example `in:devices status:online search:"core"`) reuse the cached CNPG results; only analytics-grade SRQL runs when the planner reports `engine:"srql"`.
- Prefer the registry for hot-path lookups and lean on SRQL only when a question truly needs long-range analytics. Use the quick-reference table below when choosing a data source.

| Question | Endpoint / Engine |
|----------|-------------------|
| Does device `X` exist? | `/api/devices/search` → `engine:"registry"` |
| How many devices have ICMP today? | `/api/stats` (registry snapshot backed by CNPG) |
| Search devices matching `foo` | `/api/devices/search` with `filters.search=foo` |
| ICMP RTT for last 7d / historical analytics | `/api/query` with `engine:"srql"` |

- Force SRQL only when you truly need OLAP features: pass `"mode":"srql_only"` in the planner request or visit the SRQL service directly. Registry fallbacks (`engine_reason:"query_not_supported"`) usually mean the query contains aggregates, joins, or metadata fan-out that we have not cached yet.
- When debugging unexpected SRQL load, inspect `/api/devices/search` diagnostics (`engine_reason`, `unsupported_tokens`) and confirm the feature flags stay enabled (`features.use_device_search_planner` server side, `NEXT_PUBLIC_FEATURE_DEVICE_SEARCH_PLANNER` in the web deployment).

## SRQL Service Wiring

- Ensure the core config includes an `srql` block that points at the in-cluster service. The demo ConfigMap ships with:
  ```json
  "srql": {
    "enabled": true,
    "base_url": "http://serviceradar-srql:8080",
    "timeout": "15s",
    "path": "/api/query"
  }
  ```
  The core init script injects the shared API key at startup, so no manual secret editing is required.
- Whenever you tweak the SRQL config, reapply the ConfigMap (`kubectl apply -f k8s/demo/base/configmap.yaml`) and restart the core deployment:
  ```bash
  kubectl rollout restart deployment/serviceradar-core -n demo
  kubectl rollout status deployment/serviceradar-core -n demo
  ```
- Smoke test end-to-end: run `planner-smoke` and `web-query` checks from earlier to confirm `/api/devices/search` returns `engine:"srql"` for aggregate queries, and that `/api/query` forwards diagnostics showing `engine_reason:"query_not_supported"` when SRQL satisfies the request.

## SRQL API Tests

- The SRQL crate now ships deterministic `/api/query` tests that boot a Dockerized CNPG instance (TimescaleDB + Apache AGE) and run `cargo test` against it. You need Docker running locally plus Bazel/Bazelisk available. Remote builds reuse the BuildBuddy config you use elsewhere; otherwise run `bazel run --config=no_remote //docker/images:cnpg_image_amd64_tar`.
- Prime the CNPG image once (or whenever the Docker cache is wiped). You can either pull the published build or rebuild via Bazel:
  ```bash
  docker pull ghcr.io/carverauto/serviceradar-cnpg:16.6.0-sr1
  # or, if you need to refresh the image artifacts locally:
  bazel run //docker/images:cnpg_image_amd64_tar
  ```
- Execute the API suite from the repo root (or `rust/srql` directory) and expect ~60s per run while the container boots and seeds:
  ```bash
  cd rust/srql
  cargo test --test api -- --nocapture
  ```
  The harness will build the CNPG image automatically if it is missing, but doing so up front keeps test runs predictable.
- Bazel users can run the same suite via the `//rust/srql:srql_api_test` target. Our BuildBuddy RBE executors expose Docker, so the standard workflow is:
  ```bash
  bazel test --config=remote //rust/srql:srql_api_test
  ```
  When hacking offline (or if you prefer the local Docker daemon), drop back to `--config=no_remote` instead.
- GitHub Actions runs `cargo test` for `rust/srql` on every change touching the crate, so keep the suite green locally before pushing large parser or planner updates.

## CNPG Reset (Cluster + PVC Rotation)

If the Timescale tables balloon or fall irreparably out of sync, rotate the CNPG cluster instead of hand-truncating every hypertable. The helper script below deletes the stateful set, recreates the PVCs, reapplies the manifests, runs migrations, and restarts the workloads so the schema is rebuilt from scratch:

```bash
# from repo root; defaults to the demo namespace
scripts/reset-cnpg.sh

# or explicitly choose a namespace
scripts/reset-cnpg.sh staging
```

What the script does:

- `kubectl scale cluster cnpg --replicas=0` via the CloudNativePG CR (effectively deleting the StatefulSet)
- Deletes PVCs labeled `cnpg.io/cluster=cnpg` so the next apply provisions clean volumes
- Reapplies `k8s/demo/base/spire` to recreate the CNPG cluster and SPIRE dependencies
- Waits for `cnpg-{0,1,2}` to become Ready and confirms the custom `serviceradar-cnpg` image is running
- Runs `cnpg-migrate` (with the superuser secret mounted) to seed the telemetry schema
- Restarts `serviceradar-core`, `serviceradar-sync`, and the writers so they reconnect to the new database

After the reset:

1. Spot-check counts with `/api/stats` and a direct CNPG query (`SELECT COUNT(*) FROM unified_devices`).
2. Tail `kubectl -n <ns> logs deploy/serviceradar-db-event-writer --tail=20` to confirm OTEL batches stay healthy.
3. Hard-refresh the dashboards so cached device totals drop.
4. If the issue stemmed from leftover WAL or chunk bloat, capture `timescaledb_information.hypertable_detailed_size('timeseries_metrics')` before and after to document the improvement.

Run the script in staging first; it is idempotent and leaves the namespace with a fully bootstrapped CNPG instance that matches the schema in `pkg/db/cnpg/migrations`.

## CNPG Client From `serviceradar-tools`

- Launch the toolbox with `kubectl exec -it -n demo deploy/serviceradar-tools -- bash`. The pod mounts the CNPG CA + credentials at `/etc/serviceradar/cnpg` and exposes helper aliases in the MOTD.
- `cnpg-info` prints the effective DSN, TLS mode, and username so you can quickly confirm which namespace you are targetting.
- `cnpg-sql` wraps `psql` with the right certificates. A few handy snippets:
  ```bash
  cnpg-info
  cnpg-sql "SELECT count(*) FROM unified_devices"
  cnpg-sql "SELECT hypertable_name, total_bytes/1024/1024 AS mb FROM timescaledb_information.hypertable_detailed_size ORDER BY total_bytes DESC LIMIT 5"
  cnpg-migrate --app-name serviceradar-tools
  ```
- You can run any of those without an interactive shell:
  ```bash
  kubectl exec -n demo deploy/serviceradar-tools -- \
    cnpg-sql "SELECT NOW()"
  ```
- Outside the cluster, port-forward the RW service and export the `CNPG_*` environment variables before running `make cnpg-migrate` or `psql`. The helpers respect `CNPG_PASSWORD_FILE`, so you can pass `/etc/serviceradar/cnpg/superuser-password` directly instead of copying secrets to your laptop.
- JetStream helpers still share the `serviceradar` context; the same pod gives you `nats-streams`, `nats-events`, and `nats-kv` for quick config or replay checks.

## Sweep Config Distribution

- Agents still read `agents/<id>/checkers/sweep/sweep.json` from disk first, then apply any JSON overrides stored in the KV bucket via `pkg/config`. This preserves the existing knobs for intervals, timeout, and protocol selection.
- Sync now streams the per-device target list into JetStream object storage through the `proto.DataService/UploadObject` RPC before updating KV. The pointer that lands in KV carries `storage: "data_service"`, the object key, and the SHA-256 digest so downloads can be verified.
- When the agent sees the pointer metadata it layers the downloaded object _after_ file + KV overlays. If the DataService call fails (for example older clusters that only expose the legacy KV service) the agent logs a warning and falls back to the KV/file configuration with no sweep targets.
- Atomicity: the object is uploaded first; only after `UploadObject` returns do we write the metadata pointer. A partially written pointer is therefore either the previous revision or a fully verified new blob.
- Manual inspection:
  ```bash
  # List sweep blobs (default bucket is serviceradar-sweeps)
  kubectl exec -n demo deploy/serviceradar-tools -- \
    nats --context serviceradar obj ls serviceradar-sweeps

  # Fetch the latest sweep payload for an agent
  kubectl exec -n demo deploy/serviceradar-tools -- \
    nats --context serviceradar obj get serviceradar-sweeps agents/demo-agent/checkers/sweep/sweep.json |
    jq '.device_targets | length'
  ```

## Timescale Retention & Compression Checks

> Need a long-lived dashboard instead of ad-hoc SQL? Follow the [CNPG Monitoring guide](./cnpg-monitoring.md) to add Grafana panels for ingestion volume, job status, and pgx waiters. The queries below remain the fastest way to double-check results directly from the toolbox.

- Every hypertable created by the migrations already registers a retention policy (3 days for most telemetry, 30 days for services). Confirm the jobs are firing with:
  ```bash
  kubectl exec -n demo deploy/serviceradar-tools -- \
    cnpg-sql "SELECT job_id, job_type, hypertable_name, last_successful_finish FROM timescaledb_information.job_stats ORDER BY job_id"
  ```
- Compression stays disabled by default. When you enable it for a table, follow up with a health check so we know chunks are being reordered/compressed: `SELECT hypertable_name, compression_enabled, compressed_chunks, uncompressed_chunks FROM timescaledb_information.hypertable_compression_stats`.
- If retention falls behind, force a run with `SELECT alter_job(job_id => <id>, next_start => NOW());` or manually drop old chunks: `SELECT drop_chunks('timeseries_metrics', INTERVAL '3 days');`.
- Run the quick `hypertable_detailed_size` query before and after maintenance to quantify the impact:
  ```bash
  cnpg-sql "SELECT hypertable_name, total_bytes/1024/1024 AS mb FROM timescaledb_information.hypertable_detailed_size ORDER BY total_bytes DESC LIMIT 10"
  ```
- Use `CALL refresh_continuous_aggregate('device_metrics_summary_cagg', NULL, NULL);` whenever you bulk load data or truncate telemetry so the dashboards immediately reflect the changes.

## Canonical Identity Flow

- Sync no longer BatchGets canonical identity keys; the `core` registry now hydrates canonical IDs per batch using the `device_canonical_map` KV (`WithIdentityResolver`).
- Expect `serviceradar-core` logs to show non-zero `canonicalized_by_*` counters once batches replay. If they stay at 0, recheck KV health via `nats-kv` (or the `nats-datasvc` alias) and ensure `serviceradar-core` pods run the latest image.
- Toolbox helper to spot-check canonical entries:
  ```bash
  kubectl exec -n demo deploy/serviceradar-tools -- \
    cnpg-sql "SELECT COUNT(*) AS devices, COUNT(DISTINCT metadata->>'armis_device_id') AS armis_ids FROM unified_devices"
  nats --context serviceradar kv get device_canonical_map/armis-id/<ARMIS_ID>
  ```

## Common Error Notes

- `rpc error: code = Unimplemented desc =` – emitted by core when the poller is stopped; safe to ignore while the pipeline is paused.
- `json: cannot unmarshal object into Go value of type []*models.DeviceUpdate` – happens if the discovery queue contains an object instead of an array. Clearing the queue and replaying new discovery data resolves it.
- `cnpg device_updates batch: invalid input syntax for type json` – indicates a writer emitted malformed metadata. Inspect the offending payload (`db.UpdateDevice.METADATA`) and patch the producer before replaying.
- `ERROR: duplicate key value violates unique constraint "unified_devices_pkey"` – normally caused by reusing the same `device_id` + `_merged_into` metadata after a reset. Run the pipeline reset above to clear stale rows, then replay once so the merge helper can rebuild the canonical view cleanly.

## Investigating Slow CNPG Queries

Use the pre-authenticated `serviceradar-tools` deployment whenever you need to inspect Timescale load:

```bash
# Shell into the toolbox (optional; commands below exec directly)
kubectl exec -it -n demo deploy/serviceradar-tools -- bash
```

- **Top queries by mean runtime (pg_stat_statements)**    ```bash
  kubectl exec -n demo deploy/serviceradar-tools -- \
    cnpg-sql "SELECT query, calls, round(mean_exec_time,2) AS ms, total_exec_time 
              FROM pg_stat_statements
              ORDER BY mean_exec_time DESC
              LIMIT 10"
  ```
  Make sure the `pg_stat_statements` extension exists (`CREATE EXTENSION IF NOT EXISTS pg_stat_statements;`).
- **Active sessions + blocking chains**    ```bash
  kubectl exec -n demo deploy/serviceradar-tools -- \
    cnpg-sql "SELECT pid, wait_event_type, wait_event, state, query
              FROM pg_stat_activity
              WHERE datname = current_database()
              ORDER BY state, query_start"
  ```
  Hung inserts almost always show up here with a `wait_event_type` of `Lock`.
- **Explain a specific query**    ```bash
  kubectl exec -n demo deploy/serviceradar-tools -- \
    cnpg-sql "EXPLAIN (ANALYZE, BUFFERS, VERBOSE) \n              SELECT * FROM unified_devices ORDER BY last_seen DESC LIMIT 50"
  ```
  Attach the plan when filing perf bugs so we can see whether Timescale is hitting the new indexes.
- **Chunk-level stats**    ```bash
  cnpg-sql "SELECT hypertable_name, chunk_name, approx_row_count
            FROM timescaledb_information.chunks
            ORDER BY approx_row_count DESC LIMIT 10"
  ```
  Large, uncompressed chunks usually point to retention/compression jobs falling behind.

Once you have the offending query, correlate it with the Go/UI call site and either add the missing index or route the workload through the registry cache.

## Quick Reference Commands

```bash
# Run a SQL statement against CNPG from the toolbox
kubectl exec -n demo deploy/serviceradar-tools -- \
  cnpg-sql "SELECT COUNT(*) FROM unified_devices"

# Count devices per poller (helpful when validating faker replays)
kubectl exec -n demo deploy/serviceradar-tools -- \
  cnpg-sql "SELECT poller_id, COUNT(*) FROM unified_devices GROUP BY poller_id ORDER BY count DESC"

# Port-forward CNPG locally and run migrations from your laptop
kubectl port-forward -n demo svc/cnpg-rw 55432:5432 &
export CNPG_HOST=127.0.0.1 CNPG_PORT=55432 CNPG_DATABASE=telemetry
export CNPG_USERNAME=postgres
export CNPG_PASSWORD=$(kubectl get secret -n demo cnpg-superuser -o jsonpath='{.data.password}' | base64 -d)
make cnpg-migrate
```

Keep this document up to date as we refine the tooling around the agents and the demo environment.
