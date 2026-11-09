# ServiceRadar NVR

`serviceradar-nvr` is the independently deployable recording runtime. Its Elixir
application is `serviceradar_nvr`; media packaging and journaled block writing
come from `serviceradar_recording`. Core uses the same writer and retains its
existing authorization, database leases and publication path.

This checkpoint processes finite local blocks through a trusted, same-VM API.
It has no camera source connector, assignment protocol, upload worker or playback
catalog. Starting the service does not start recording. It does not join an
Erlang distribution cluster or start core, a Repo, NATS or libcluster.

## Runtime boundary

`ServiceRadarNVR.start_recording(identity, clock)` returns a worker and a bounded
`ServiceRadarRecording.Inbox`. The caller is its sole producer. Pass the inbox's
`media_ingest_id` with each complete H264 AnnexB access unit to `Inbox.offer/2`,
and call `Inbox.finish/1` to drain in order. `ServiceRadarNVR.status/1` reports
progress; `stop/1` cancels without advertising a sealed recording. The producer
receives `{:nvr_recording, pid, result}`. A successful result contains an internal
sealed local snapshot, not authorization, an archive proof or a catalog receipt.

The shared writer preserves clock provenance and checks admission around every
spool mutation. Workers are temporary: a crash, deadline, discontinuity or lost
producer never automatically restarts capture. Failure retains provisional bytes
for explicit recovery. Only one local worker can own a source/profile, even with
a different epoch. This registry is not a cross-replica fence; future authenticated
assignment must establish physical writer exclusivity before calling this API.

## Resource envelope

| Setting | Default | Ceiling / behavior |
| --- | --- | --- |
| `SERVICERADAR_NVR_MAX_SESSIONS` | 1 | 16; excess admission is refused |
| `SERVICERADAR_NVR_MAX_DURATION_MS` | 30000 | 300000; no implicit renewal |
| `SERVICERADAR_NVR_MAX_SPOOL_BYTES` | 1073741824 | 1 TiB; retained bytes plus full active reservations |
| `SERVICERADAR_NVR_RESERVE_BYTES` | 67108864 | 1 PiB; physical free-space floor; admission also needs all reservations free |
| Inbox | 8 samples / 8 MiB per worker | charged before mailbox admission |
| Local block | 16 MiB / 8 fragments | no rotation, eviction or deletion |
| Fragment | 4 MiB | oversized output fails the worker |
| VM | 2 schedulers / 32768 processes / 4096 ports | release VM arguments |
| Kubernetes | 2 CPU / 1 GiB memory per replica | configurable container limits |

These are finite runtime limits, not measured camera capacity. Storage replication,
physical I/O budgets and continuous-policy admission remain qualification work.
Network endpoints only serve health probes:
`GET /healthz` means the runtime is live; `/readyz` additionally verifies the
configured private storage root and identity. Neither admits a recording pool.

Before starting a worker, the serialized capacity owner charges one maximum block
(init, media and journal) against both the spool budget and available disk space.
It counts existing sealed, partial and abandoned files without recovering or
deleting them. Worker exit releases its reservation, not its retained bytes.
`ServiceRadarNVR.capacity/0` returns a read-only observation of usage, full active
reservations and available space; it is not a promise to a future caller.

Inventory accepts at most 4096 block directories with the existing spool file
names. Unknown entries, aliases and unreadable inventory refuse admission and
remain intact. Admission conservatively counts active bytes both as inventory
and as full reservations. It can refuse early; it cannot spend that slack on a
second worker. Losing the capacity owner retires dependent workers before the
replacement owner accepts reservations. Restart inventories the retained volume.

Linux hosts need GNU coreutils `/usr/bin/stat` and `/usr/bin/timeout`, supplied by
the Ubuntu image. Available space uses non-root available blocks and fundamental
block size, with a two-second probe deadline and one-second kill grace. Every
admission probes afresh; write guards reuse a pressure observation for at most one
second. Admission requires the floor plus every full reservation, including the
new block, to be available. After admission a worker may consume its reserved
space; write guards stop it only when available space falls below the floor
itself. A failed probe or a breached floor terminates the affected worker on its
next write guard and retains provisional media. Idle workers still have their finite
deadline. This floor is an admission/stop policy, not a preallocated filesystem
partition or protection against other applications consuming the volume. Reserve
filesystem metadata, recovery and control headroom when sizing the dedicated PVC.

## Persistent storage and replicas

See [NVR storage and deployment](../../docs/nvr-runtime.md). Kubernetes uses a
StatefulSet with one retained PVC per ordinal. Longhorn or Ceph can supply
replication; NVR does not replicate video between workers. Local-only retention
is supported without S3, provided storage is qualified for worker-node loss.
S3 archival also needs a protected spool for footage awaiting upload.

## Build and validation

```sh
bazel build --config=remote //elixir/serviceradar_nvr:release_tar
bazel build --config=remote //docker/images:nvr_image_multiarch
bazel test --config=remote //elixir/serviceradar_nvr:release_test
```

The release test starts the shipped VM without control-plane services, exercises
bounded worker admission and retirement, spool budget, free-space floor and
inventory refusal, records synthetic H264, restarts the release, recovers the
journal and compares decoded frames. Core's existing
recording integration suite owns the CNPG authorization/publication contract.
Physical node-loss durability and deployed camera behavior are not established
by these synthetic tests.
