# ServiceRadar NVR

`serviceradar-nvr` is the independently deployable recording runtime. Its Elixir
application is `serviceradar_nvr`; media packaging and journaled block writing
come from `serviceradar_recording`. Core uses the same writer and retains its
existing authorization, database leases and publication path. Both consume the
metadata-only `serviceradar_recording_metadata` contract.

This checkpoint processes finite recording sessions through a trusted, same-VM API.
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

When a complete fragment would exceed the current block's byte or fragment
limit, the writer seals that block and sends
`{:nvr_block_sealed, pid, %{snapshot: snapshot, init_format: init_format}}`.
It then rechecks aggregate capacity before creating the next block with an
incremented block sequence and the same verified initialization data. The
packager continues, preserving frame and clock continuity. Terminal success
contains the final block; callers consume earlier block notifications separately.
No list of completed snapshots accumulates in the worker.

Rotation neither renews the session deadline nor restarts acquisition. If the
next reservation fails, capture stops and the sealed block remains on disk;
the fragment awaiting a new block is not advertised as recorded. Notifications
are process-local hints, not durable publication or an outbox. A crash can leave
sealed or provisional journaled bytes without a delivered notification.

The shared writer preserves clock provenance and checks admission around every
spool mutation. Workers are temporary: a crash, deadline, discontinuity or lost
producer never automatically restarts capture. Failure retains provisional bytes
for explicit recovery. Only one local worker can own a source/profile, even with
a different epoch. This registry is not a cross-replica fence; future authenticated
assignment must establish physical writer exclusivity before calling this API.

## Read-only restart discovery

Trusted same-VM callers can use `ServiceRadarNVR.list_blocks/0` after restart to
list retained block IDs, without saved notifications or receipts. It uses the
same verified storage identity and bounded inventory as admission: at most 4096
block directories, with aliases and unknown file names refused. The list can
include incomplete or corrupt blocks and is not an atomic coverage catalog;
recording may add blocks after enumeration.

`ServiceRadarNVR.sealed_block/1` verifies one listed block and returns an internal
sealed snapshot, including `init_format` (SHA-256, timescale and baseline AVC
codec declaration) reconstructed from verified `init.mp4` bytes. Live packaging
uses the same parser, so this metadata survives loss of the writer's memory and
notifications without a new sidecar or journal version. The parser requires one
AVC track and one sample description; unsupported or malformed initialization
returns `:invalid_initialization`. Block inspection also checks the journal,
initialization and fragment digests, whole-block seal, identity-derived directory
name and exact file lengths under
the runtime's block limits. Inspection runs in the caller, outside serialized
capacity admission. It never truncates, seals, repairs or deletes anything.
Unsealed blocks, uncommitted tails and corrupt evidence return errors and remain
on disk for separate reconciliation. Existing explicit `Spool.recover/4` still
requires expected identity and exclusive ownership before repairing tails.

`ServiceRadarNVR.block_descriptor/1` performs the same read-only verification
and returns canonical v1 JSON for the sealed block: identity, clock, native format,
initialization/media digests and fragment ranges. It uses the same descriptor
validator as Core's frozen blocks and archive manifests. The bytes contain no
local paths or storage receipts; the API is trusted same-VM only, with no HTTP
endpoint. No descriptor sidecar is persisted.

These observations do not establish current assignment authority, physical
storage durability, publication receipts or playback authorization. They do not
acknowledge delivery or drain a durable outbox. No automatic scan or capture
restart runs at boot; publication, assignment reconciliation and unresolved/gap
state remain follow-up work.

## Explicit interrupted-block recovery

After retiring the previous writer and establishing exclusive volume attachment,
a trusted same-VM caller may invoke
`ServiceRadarNVR.recover_block(block_id, expected_identity)`. The expected identity
includes the original source, profile, recorder epoch, block sequence and clock
provenance. A directory name alone is insufficient. This is an explicit operation;
startup does not repair blocks or resume capture.

Recovery refuses while any local writer holds a reservation. The capacity owner
serializes the entire bounded repair against new admission, checks the retained
inventory and physical free-space floor, and verifies the configured storage
identity. It does not need capacity for a new media block. This local exclusion
does not fence another process, replica or node; qualified attachment fencing and
assignment reconciliation remain independent requirements.

The shared journal reader verifies all committed fragments before changing any
bytes. Recovery discards only media beyond the committed high-water mark and an
incomplete journal tail, then durably seals the nonempty prefix. It preserves
the original identity and fragment timing. Complete corrupt records, mismatched
identities, misplaced directories, empty blocks and changed initialization files
are refused without repair. It never deletes a block or replaces committed media.
Filesystem errors during repair can leave partial progress; retry the same
operation after resolving the error. A timeout is an unknown outcome, not proof
that nothing changed. Repeating a successful recovery returns the same sealed
snapshot without adding another seal. The snapshot includes the same byte-derived
`init_format` as read-only inspection. Format decoding runs after journal recovery;
an initialization format error can therefore follow a successful repair/seal.
The retained bytes remain available for reconciliation. A successful integrity
check alone does not establish a supported media format.

The resulting snapshot is local recovery evidence. Missing buffered frames are
not recovered or advertised. Durable gap reporting, catalog publication, playback
authorization and automatic assignment reconciliation remain pending.

## Resource envelope

| Setting | Default | Ceiling / behavior |
| --- | --- | --- |
| `SERVICERADAR_NVR_MAX_SESSIONS` | 1 | 16; excess admission is refused |
| `SERVICERADAR_NVR_MAX_DURATION_MS` | 30000 | 300000; no implicit renewal |
| `SERVICERADAR_NVR_MAX_SPOOL_BYTES` | 1073741824 | 1 TiB; retained bytes plus full active reservations |
| `SERVICERADAR_NVR_RESERVE_BYTES` | 67108864 | 1 PiB; physical free-space floor; admission also needs all reservations free |
| Inbox | 8 samples / 8 MiB per worker | charged before mailbox admission |
| Local block | 16 MiB / 8 fragments | rotate at a complete fragment boundary; no eviction or deletion |
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
At rotation the capacity owner atomically replaces that worker's reservation
after inventorying the sealed block. There is no release/reacquire gap, and
other active reservations remain charged.
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
journals and compares decoded frames, including across multiple blocks and after
refusing a successor block. Core's existing
recording integration suite owns the CNPG authorization/publication contract.
Physical node-loss durability and deployed camera behavior are not established
by these synthetic tests.
