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
- Expect `serviceradar-core` logs to show non-zero `canonicalized_by_*` counters once batches replay. If they stay at 0, recheck KV health via `nats-kv` and ensure `serviceradar-core` pods run the latest image.
- Toolbox helper to spot-check canonical entries:
  ```bash
  proton-sql "SELECT count(), uniq_exact(metadata['armis_device_id']) FROM table(unified_devices)"
  nats --context serviceradar kv get device_canonical_map/armis-id/<ARMIS_ID>
  ```

## Common Error Notes

- `rpc error: code = Unimplemented desc =` – emitted by core when the poller is stopped; safe to ignore while the pipeline is paused.
- `json: cannot unmarshal object into Go value of type []*models.DeviceUpdate` – happens if the discovery queue contains an object instead of an array. Clearing the streams and replaying new discovery data resolves it.
- `TOO_LARGE_RECORD` when inserting into `unified_devices_registry` – confirm the streaming safeguards above are active, replay stuck data with `proton-sql "DROP VIEW IF EXISTS unified_device_pipeline_mv"` followed by the migration definition, and, when necessary, re-shard replays (hash on `device_id`) so every insert batch remains under ~4 MiB.

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
