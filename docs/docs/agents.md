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

   ```sql
   DROP VIEW IF EXISTS unified_device_pipeline_mv;

   CREATE MATERIALIZED VIEW unified_device_pipeline_mv
   INTO unified_devices
   AS
   SELECT
       device_id,
       arg_max_if(ip, timestamp, is_active AND has_identity) AS ip,
       arg_max_if(poller_id, timestamp, is_active AND has_identity) AS poller_id,
       arg_max_if(agent_id, timestamp, is_active AND has_identity) AS agent_id,
       arg_max_if(hostname, timestamp, is_active AND has_identity) AS hostname,
       arg_max_if(mac, timestamp, is_active AND has_identity) AS mac,
       group_uniq_array_if(discovery_source, is_active AND has_identity) AS discovery_sources,
       arg_max_if(available, timestamp, is_active AND has_identity) AS is_available,
       min_if(timestamp, is_active AND has_identity) AS first_seen,
       max_if(timestamp, is_active AND has_identity) AS last_seen,
       arg_max_if(metadata, timestamp, is_active AND has_identity) AS metadata,
       'network_device' AS device_type,
       CAST(NULL AS nullable(string)) AS service_type,
       CAST(NULL AS nullable(string)) AS service_status,
       CAST(NULL AS nullable(DateTime64(3))) AS last_heartbeat,
       CAST(NULL AS nullable(string)) AS os_info,
       CAST(NULL AS nullable(string)) AS version_info
   FROM (
       SELECT
           device_id,
           ip,
           poller_id,
           agent_id,
           hostname,
           mac,
           discovery_source,
           available,
           timestamp,
           metadata,
           coalesce(metadata['_merged_into'], '') AS merged_into,
           lower(coalesce(metadata['_deleted'], 'false')) AS deleted_flag,
           coalesce(metadata['armis_device_id'], '') AS armis_device_id,
           coalesce(metadata['integration_id'], metadata['netbox_device_id'], '') AS external_id,
           coalesce(mac, '') AS mac_value,
           (coalesce(metadata['_merged_into'], '') = '' AND lower(coalesce(metadata['_deleted'], 'false')) != 'true') AS is_active,
           (
               coalesce(metadata['armis_device_id'], '') != ''
               OR coalesce(metadata['integration_id'], metadata['netbox_device_id'], '') != ''
               OR coalesce(mac, '') != ''
           ) AS has_identity
       FROM device_updates
   ) AS src
   GROUP BY device_id
   HAVING count_if(is_active AND has_identity) > 0;

   ALTER STREAM unified_devices
       DELETE WHERE coalesce(metadata['_merged_into'], '') != ''
          OR lower(coalesce(metadata['_deleted'], 'false')) = 'true'
          OR (
               coalesce(metadata['armis_device_id'], '') = ''
               AND coalesce(metadata['integration_id'], metadata['netbox_device_id'], '') = ''
               AND coalesce(mac, '') = ''
          );

   ALTER STREAM unified_devices_registry
       DELETE WHERE coalesce(metadata['_merged_into'], '') != ''
          OR lower(coalesce(metadata['_deleted'], 'false')) = 'true'
          OR (
               coalesce(metadata['armis_device_id'], '') = ''
               AND coalesce(metadata['integration_id'], metadata['netbox_device_id'], '') = ''
               AND ifNull(mac, '') = ''
          );
   ```

4. **Reseed canonical tables** – replay the current discovery stream into `unified_devices` and `unified_devices_registry`:

   ```sql
   INSERT INTO unified_devices
   (device_id, ip, poller_id, agent_id, hostname, mac, discovery_sources,
    is_available, first_seen, last_seen, metadata, device_type,
    service_type, service_status, last_heartbeat, os_info, version_info)
   SELECT
       s.device_id,
       s.ip,
       s.poller_id,
       s.agent_id,
       s.hostname,
       s.mac,
       [s.discovery_source],
       coalesce(s.available, false),
       s.timestamp,
       s.timestamp,
       s.metadata,
       'network_device',
       NULL,
       NULL,
       NULL,
       NULL,
       NULL
   FROM table(device_updates) AS s;

   -- The registry is versioned_kv so insert in smaller batches.
   INSERT INTO unified_devices_registry
   SELECT * FROM table(unified_devices);
   ```

   If the registry insert exceeds the 10 MB batch limit, split it by hashing the device IDs:

   ```sql
   INSERT INTO unified_devices_registry
   SELECT * FROM table(unified_devices)
   WHERE modulo(city_hash64(device_id), 10) = 0;  -- repeat for 1..9
   ```

   (The usable function name is `city_hash64`.)

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
