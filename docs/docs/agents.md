---
sidebar_position: 12
title: Agents & Demo Operations
---

# Agents & Demo Operations

This runbook captures the operational steps we used while debugging the canonical device pipeline in the demo cluster. It focuses on the pieces that interact with the "agent" side of the world (faker → sync → core) and the backing Timeplus/Proton database.

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

This clears Timeplus/Proton and repopulates it with a fresh discovery crawl from the faker service.

1. **Quiesce sync** – stop new writes while we clear the streams:

   ```bash
   kubectl scale deployment/serviceradar-sync -n demo --replicas=0
   ```

2. **Truncate Proton streams** – run the following against the `default` database (each command can be executed with `curl` from a toolbox pod):

   ```sql
   ALTER STREAM device_updates DELETE WHERE 1;
   ALTER STREAM unified_devices DELETE WHERE 1;
   ALTER STREAM unified_devices_registry DELETE WHERE 1;
   ```

   After the deletes, verify counts:

   ```sql
   SELECT count() FROM table(device_updates);
   SELECT count() FROM table(unified_devices);
   SELECT count() FROM table(unified_devices_registry);
   ```

3. **Ensure the materialized view exists** – drop and recreate `unified_device_pipeline_mv` so it reflects the current schema and filters tombstoned rows (`_merged_into`, `_deleted`):

The latest schemas can be found in @pkg/db/migrations

5. **Verify counts** – typical numbers for the demo environment:

   ```sql
   SELECT count() FROM table(unified_devices);             -- ≈ 50–70k
   SELECT uniq_exact(metadata['armis_device_id']) FROM table(unified_devices);
   SELECT count() FROM table(unified_devices_registry);
   ```

6. **Resume discovery** – start the sync pipeline again:

   ```bash
   kubectl scale deployment/serviceradar-sync -n demo --replicas=1
   kubectl logs deployment/serviceradar-sync -n demo --tail 50
   ```

Once the sync pod reports “Completed streaming results”, the canonical tables will match the faker dataset.

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

- All Rust collectors now link the shared bootstrap library and pull KV at boot. If you need to rehydrate configs manually, exec into the pod and write the baked template back to disk:

  ```bash
  kubectl exec -n demo deploy/serviceradar-flowgger -- \
    cp /etc/serviceradar/templates/flowgger.toml /etc/serviceradar/flowgger.toml
  ```

  The service will reseed KV on next start; no separate `config-sync` sidecar is required.
- Hot reload is unified across OTEL, flowgger, trapd, and zen: when `CONFIG_SOURCE=kv`, each binary calls `config_bootstrap::watch()` and relies on the shared `RestartHandle` helper. Any `nats-kv put config/<service>` will log `KV update detected; restarting process to apply new config`, spawn a fresh process, and exit the old one so supervisors/container runtimes apply the overlay. Set `CONFIG_SOURCE=file` (or the service-specific `*_SEED_KV=false`) if you need to temporarily disable the watcher in lab environments.

## Device Registry Feature Flags

- Set `features.require_device_registry` (in `serviceradar-config` → `core.json`) to `true` once the registry/search stack is stable. It blocks `/api/devices` and `/api/devices/{id}` from falling back to Proton so hot-path reads stay in-memory. Flip it back to `false` only if you need the legacy Proton endpoints during an incident.
- Keep `features.use_device_search_planner` enabled alongside the web flag `NEXT_PUBLIC_FEATURE_DEVICE_SEARCH_PLANNER` so inventory traffic routes through the planner instead of hitting Proton directly.

### Post-Rollout Verification (demo)

Run these checks after flipping `require_device_registry` or deploying new core images:

1. **Registry hydration**  
   ```bash
   kubectl logs deployment/serviceradar-core -n demo --tail=100 | \
     rg "Device registry hydrated"
   ```
   Expect a log line with `device_count` matching Proton (`~50k` in demo).

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

### Proton vs Registry Query Guidance

- Treat `/api/devices/search` as the front door for inventory queries. The planner decides whether the in-memory registry or SRQL should execute the request and always includes `engine` + `engine_reason` diagnostics so you can verify the path that ran.
- The web proxy at `/api/query` now runs the same planner first. Registry-capable queries (for example `in:devices status:online search:"core"`) return cached registry results; analytics-grade SRQL still flows through when the planner reports `engine:"srql"`.
- Prefer the registry for hot-path lookups. Use the quick-reference table below when choosing a data source.

| Question | Endpoint / Engine |
|----------|-------------------|
| Does device `X` exist? | `/api/devices/search` → `engine:"registry"` |
| How many devices have ICMP today? | `/api/stats` (registry snapshot) |
| Search devices matching `foo` | `/api/devices/search` with `filters.search=foo` |
| ICMP RTT for last 7d / historical analytics | Direct SRQL (`/api/query` with `mode:"srql_only"` if needed) |
- Force SRQL only when you truly need OLAP features: pass `"mode":"srql_only"` in the planner request or visit the SRQL service directly. Registry fallbacks (`engine_reason:"query_not_supported"`) usually mean the query contains aggregates, joins, or metadata fan-out that we have not cached yet.
- When debugging unexpected SRQL load, inspect `/api/devices/search` diagnostics (`engine_reason`, `unsupported_tokens`) and confirm feature flags stay enabled (`features.use_device_search_planner` server side, `NEXT_PUBLIC_FEATURE_DEVICE_SEARCH_PLANNER` in the web deployment).

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

## Proton Reset (PVC Rotation)

If the telemetry tables balloon again, it is faster to rotate Proton’s volume than to hand-truncate every dependent stream. The helper script below scales Proton down, recreates the PVC, brings Proton back online, and restarts core so it can rebuild the schema from scratch:

```bash
# from repo root; defaults to the demo namespace
scripts/reset-proton.sh

# or explicitly choose a namespace
scripts/reset-proton.sh staging
```

What the script does:

- `kubectl scale deployment/serviceradar-proton --replicas=0`
- Delete and recreate the `serviceradar-proton-data` PVC (512 Gi by default, override with `PVC_SIZE` and `STORAGE_CLASS`)
- Scale Proton back up and wait for the rollout to finish
- `kubectl rollout restart deployment/serviceradar-core` so the schema is reseeded immediately

After the reset:

1. Spot-check counts with either `/api/query` or the Proton client (`SELECT count() FROM otel_traces`, `otel_spans_enriched`, `otel_metrics`, `otel_trace_summaries`).
2. Tail `kubectl -n <ns> logs deploy/serviceradar-otel --tail=20` to confirm span batches stay in the single digits.
3. Hard-refresh the dashboards so cached trace totals drop.
4. If storage pressure was triggered by Proton's native log backlog, use the downtime to prune the large UUID folders under `/var/lib/proton/nativelog/log/default/`. This is a once-off recovery step; with the current retention caps the new pod will recreate lean segments automatically.

## Proton Client From `serviceradar-tools`

- Launch the toolbox with `kubectl exec -it -n demo deploy/serviceradar-tools -- bash`. The image ships the upstream Proton CLI (`/usr/local/bin/proton.bin`) plus a wrapper (`/usr/local/bin/proton-client`) that applies ServiceRadar TLS defaults and the new glibc runtime automatically.
- The toolbox pod mounts the `serviceradar-secrets` secret at `/etc/serviceradar/credentials/proton-password`. `proton-client` reads this path (or `PROTON_PASSWORD[_FILE]`) before falling back to `/etc/proton-server/generated_password.txt`, so manual password entry is rarely required.
- Helpful commands once you are inside the pod:
  ```bash
  proton-info                        # show host/port/database/password source
  proton-version                     # SELECT version() via the wrapper
  proton-sql "SELECT 1"              # preferred SQL helper (runs proton-client)
  proton_sql 'SELECT count() FROM table(unified_devices)'
  proton-client --query 'SHOW STREAMS'
  ```
- To run a one-off query from outside the pod, export the secret directly and hand it to the wrapper:
  ```bash
  export PROTON_PASSWORD=$(kubectl -n demo get secret serviceradar-secrets \
    -o jsonpath='{.data.proton-password}' | base64 -d)
  kubectl -n demo exec deploy/serviceradar-tools -- \
    env PROTON_PASSWORD="$PROTON_PASSWORD" proton_sql 'SELECT 1'
  ```
- The raw `proton` binary is also available as `/usr/local/bin/proton.bin` for advanced troubleshooting; pass `--config-file /etc/serviceradar/proton-client/config.xml` to reuse the ServiceRadar TLS material when bypassing the wrapper.
- JetStream helpers share a context named `serviceradar`; either run the aliases from the MOTD (`nats-streams`, `nats-events`, …) or invoke the CLI directly:
  ```bash
  kubectl exec -n demo deploy/serviceradar-tools -- \
    nats --context serviceradar stream ls
  ```

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

## Proton Streaming Safeguards

- The demo Proton config now enforces conservative streaming thresholds: `queue_buffering_max_messages=50000`, `queue_buffering_max_kbytes=524288`, `fetch_message_max_bytes=524288`, `max_insert_block_size=2048` (with `max_block_size` matched in the server config), and JetStream flush caps of `shared_subscription_flush_threshold_count=2000`, `shared_subscription_flush_threshold_size=4194304 (4 MiB)`, `shared_subscription_flush_threshold_ms=500`.
- These limits prevent `TOO_LARGE_RECORD` failures without raising `log_max_record_size`. The values live in `packaging/proton/config/config.yaml` and are propagated to the `serviceradar-proton` image and ConfigMap overlays.
- Validate the active settings from the toolbox with:
  ```bash
  proton-sql "SELECT name, value FROM system.settings WHERE name IN \
    ('queue_buffering_max_messages','queue_buffering_max_kbytes', \
     'fetch_message_max_bytes','shared_subscription_flush_threshold_size', \
     'shared_subscription_flush_threshold_count','max_insert_block_size')"
  ```
- `max_block_size` currently exposes as a session-scoped setting; if you need to override it temporarily, run `proton-sql "SET max_block_size=2048"` before a large replay.
- Any change for non-demo clusters should be mirrored in the shared config and rolled via `bazel run //docker/images:serviceradar-proton_push` followed by a `kubectl rollout restart deployment/serviceradar-proton -n <namespace>`.

## Canonical Identity Flow

- Sync no longer BatchGets canonical identity keys; the `core` registry now hydrates canonical IDs per batch using the `device_canonical_map` KV (`WithIdentityResolver`).
- Expect `serviceradar-core` logs to show non-zero `canonicalized_by_*` counters once batches replay. If they stay at 0, recheck KV health via `nats-kv` (or the `nats-datasvc` alias) and ensure `serviceradar-core` pods run the latest image.
- Toolbox helper to spot-check canonical entries:
  ```bash
  proton-sql "SELECT count(), uniq_exact(metadata['armis_device_id']) FROM table(unified_devices)"
  nats --context serviceradar kv get device_canonical_map/armis-id/<ARMIS_ID>
  ```

## Common Error Notes

- `rpc error: code = Unimplemented desc =` – emitted by core when the poller is stopped; safe to ignore while the pipeline is paused.
- `json: cannot unmarshal object into Go value of type []*models.DeviceUpdate` – happens if the discovery queue contains an object instead of an array. Clearing the streams and replaying new discovery data resolves it.
- `TOO_LARGE_RECORD` when inserting into `unified_devices_registry` – confirm the streaming safeguards above are active, replay stuck data with `proton-sql "DROP VIEW IF EXISTS unified_device_pipeline_mv"` followed by the migration definition, and, when necessary, re-shard replays (hash on `device_id`) so every insert batch remains under ~4 MiB.

## Investigating Slow Proton Queries

Use the pre-authenticated `serviceradar-tools` deployment whenever you need to inspect ClickHouse load:

```bash
# Shell into the toolbox (optional; commands below exec directly)
kubectl exec -it -n demo deploy/serviceradar-tools -- bash
```

- **Top queries by bytes read (last 30 m)**  
  ```bash
  kubectl exec -n demo deploy/serviceradar-tools -- \
    proton-sql "SELECT any(query) AS sample_query,
                       sum(read_rows) AS total_rows,
                       sum(read_bytes) AS total_bytes,
                       round(sum(query_duration_ms)/1000,2) AS total_s,
                       max(query_duration_ms) AS max_ms,
                       count() AS executions
                FROM system.query_log
                WHERE event_time >= now() - INTERVAL 30 MINUTE
                  AND type = 'QueryFinish'
                GROUP BY normalized_query_hash
                ORDER BY total_bytes DESC
                LIMIT 12"
  ```
  This surfaces the normalized query shape, aggregate row/byte counts, and peak duration so you can spot hot spots quickly.

- **Same view ordered by total runtime or worst-case latency**  
  Change the `ORDER BY` clause to `total_s DESC` or `max_ms DESC` to focus on slow queries rather than volume.

- **Query volume by outcome**  
  ```bash
  kubectl exec -n demo deploy/serviceradar-tools -- \
    proton-sql "SELECT type, count() AS total
                FROM system.query_log
                WHERE event_time >= now() - INTERVAL 30 MINUTE
                GROUP BY type
                ORDER BY total DESC"
  ```
  Helpful for spotting spikes in `ExceptionWhileProcessing` or `ExceptionBeforeStart`.

- **Tighten the window**  
  Swap `INTERVAL 30 MINUTE` for `10 MINUTE` / `2 MINUTE` to see how a deploy or feature flag change impacted load in near-real time.

Once you have the offending normalized query hash, correlate it with the Go/UI code path and migrate the workload to the registry cache. This workflow kept Proton CPU near 4 % after we removed the sweep `device_id IN (...)` scans.

## Quick Reference Commands

```bash
# Run a SQL statement against Proton (default creds, database=default)
kubectl run ch-sql --rm -i --tty --image=curlimages/curl:8.9.1 -n demo --restart=Never --command -- \
  sh -c "echo <base64-sql> | base64 -d >/tmp/query.sql \
  && curl -sk -u default:<password> --data-binary @/tmp/query.sql \
     https://serviceradar-proton:8443/?database=default"

# Check distinct Armis IDs
curl -sk -u default:<password> --data-binary \
  "SELECT uniq_exact(metadata['armis_device_id']) FROM table(unified_devices)" \
  https://serviceradar-proton:8443/?database=default
```

Keep this document up to date as we refine the tooling around the agents and the demo environment.
