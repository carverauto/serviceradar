# ServiceRadar NVR

`serviceradar-nvr` is the independently deployable recording runtime. Its Elixir
application is `serviceradar_nvr`; media packaging and journaled block writing
come from `serviceradar_recording`. Core uses the same writer and retains its
existing authorization, database leases and publication path. Both consume the
metadata-only `serviceradar_recording_metadata` contract.

This checkpoint processes finite recording sessions through a trusted same-VM API
or an opt-in private TLS stream. It has no camera source connector, assignment
protocol, archive upload worker or playback catalog. Starting the service does not start recording. It does not join an
Erlang distribution cluster or start core, a Repo, NATS or libcluster.

## Private network input

An installed recording coordinator can stream complete H264 access units to
`POST /v1/recordings/ingest` over mutual TLS with a pinned client certificate and
a separate bearer token. One finite request owns one producer; TCP backpressure
waits outside the live-view pipeline. Success returns sealed local block IDs.
It does not create recording authority, register a playable copy or initialize
storage. The current bootstrap barrier still applies.

See [the wire contract and installation](../../docs/nvr-ingest.md). The shipped
release test streams synthetic media across TLS, compares decoded frames after
restart and exercises refusal and producer retirement. Inventory-driven source
assignment and the agent/gateway sender remain integration work; merely enabling
this listener does not connect an inventory camera.

## Deployment recovery admission

Runtime admission requires an external boot-pinned recovery generation and a
currently matching ready-state file. Missing or closed state refuses recording,
publication, recovery and media reads; `/healthz` stays live. State is re-read
at writer checks, publication attempts and before read replies. Offline bootstrap
evidence remains available. This is one prerequisite, not history reconciliation
or proof of replica quiescence. See the [file contract and restore limits](../../docs/nvr-runtime.md#deployment-recovery-gate).

## New-volume bootstrap

Trusted provisioning can call `ServiceRadarNVR.bootstrap_storage/3` offline with
Core's canonical preparation and the configured storage/binding reference. It
requires a private empty root and exclusive provider attachment with previous
writers retired. It syncs `.bootstrap-preparation.json` before creating
`.storage-id`; exact retries preserve bytes, and incomplete or conflicting files
are never repaired. Existing spools cannot be bootstrapped this way.

`ServiceRadarNVR.acknowledge_bootstrap/3` retains Core's exact correlated
installation acknowledgement after re-syncing the preparation and marker.
`ServiceRadarNVR.bootstrap_evidence/2` reads both bounded records and reports
their exact bytes, digests, state and retained/pending control-byte counts. It
does not sync or repair files. Each JSON record is at most 512 bytes; the
37-byte marker is included in accounting. These remain offline operations on
an exclusively attached new volume, not retained-media reconciliation.

Either bootstrap record keeps inventory and write admission closed pending
current-history reconciliation and the separate completion protocol. No startup
path bootstraps or enables recording. See [the bootstrap contract](../../docs/nvr-runtime.md#explicit-new-volume-installation)
for the API, persistence order and unresolved-state behavior.

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
the runtime's block limits. Inspection uses the bounded read pool, outside
serialized recording capacity admission. It never truncates, seals, repairs or deletes anything.
Unsealed blocks, uncommitted tails and corrupt evidence return errors and remain
on disk for separate reconciliation. Existing explicit `Spool.recover/4` still
requires expected identity and exclusive ownership before repairing tails.

`ServiceRadarNVR.block_descriptor/1` performs the same read-only verification
and returns canonical v1 JSON for the sealed block: identity, clock, native format,
initialization/media digests and fragment ranges. It uses the same descriptor
validator as Core's frozen blocks and archive manifests. The bytes contain no
local paths or storage receipts; the API is trusted same-VM only, with no HTTP
endpoint. Descriptor inspection itself does not persist a sidecar.

These observations do not establish current assignment authority, physical
storage durability, publication receipts or playback authorization. They do not
acknowledge delivery or drain a durable outbox. Opt-in publication scheduling is
described below. Capture restart, assignment reconciliation and unresolved/gap
state remain follow-up work.

## Durable local publication intent

After establishing the original frozen recording authority in Core, trusted
same-VM code may call `ServiceRadarNVR.prepare_publication(block_id, reference)`.
The reference has canonical UUIDs `:operation_id` and `:recording_block_id`, plus
`:descriptor_sha256` from that frozen descriptor. These values correlate the
future catalog operation; accepting their syntax does not verify Core authority.
There is no network endpoint or automatic creation of publication authority.

Preparation verifies the complete sealed media and reconstructs its canonical
descriptor before comparing the expected digest. It exclusively creates a private
`publication.json` within that block directory, then syncs the file and directory
before returning `{:ok, canonical_json}`. The version-1 record contains storage
UUID, local block ID, operation UUID, Core block UUID, descriptor digest and the
complete descriptor. It has a 64 KiB ceiling, no paths or S3 receipts, and one
immutable intent per block. Exact retries compare and sync the same bytes without
rewriting; a different operation, Core block reference or content is refused.
An interrupted partial file remains unresolved evidence and is never repaired or
overwritten by a retry. A timeout is an unknown outcome, not proof of no write.

`ServiceRadarNVR.publication_intent(block_id)` reads through the bounded read pool,
re-verifies media and reconstructs the entire expected record. Corrupt, oversized,
noncanonical, misbound or aliased intent files are refused. This read does not
sync a recovered file; retry preparation to obtain a durable-write acknowledgement
after a previously unknown outcome. Inspection grants neither historical
authority nor catalog availability, holds, deletion or playback permission.

Preparation and acknowledgement share one supervised publication task, with no
waiting queue. Saturation returns `:nvr_publication_capacity`. Verification and
file/directory syncs run outside the capacity owner, so admitted recording, new
recording admission and rotation can continue. The task has a thirty-second
deadline that survives caller loss. A timeout or task failure is an unknown
outcome: inspect or retry the same immutable operation. Only task exit releases
its slot and pending-write reservation. A publication supervisor restart retires
its tasks without stopping recording; loss of capacity accounting retires both.

Before writing, the task asks the capacity owner to check fresh inventory and
free space. New bytes must fit alongside full active media reservations, the
configured physical floor and all other publication allowances. The write spends
its own missing-record allowance; its complete byte count remains reserved until
the task exits, even when inventory already sees the file. Write guards keep both
that allowance and the pending bytes until fresh inventory after task exit; a
failed inventory keeps the previous floor. This conservative
accounting may refuse admission early. Exact retries need no additional bytes.
Recovery remains exclusive with both recording and publication.

Broader control reserves for holds/disposition, authenticated authority delivery,
qualified local-copy catalog registration and preservation/disposition state
remain open under the
[local publication contract](../../openspec/changes/add-scalable-camera-recording-plane/local-publication.md).
No recording is advertised or media deleted by either API.

Core now exposes the trusted in-process
`ServiceRadar.Camera.LocalPublicationIntents.accept(bytes, opts)` boundary. It
validates the shared v1 codec and locks the original frozen block to match its
storage UUID, block key, descriptor and digest. It durably stores one immutable
intent acknowledgement per block, using the supplied operation UUID as its ID.
After the immutable row commits, Core returns canonical acknowledgement JSON
with `version: 1`, `kind: "intent_accepted"`, the operation UUID and the SHA-256
of the complete canonical intent. Exact retries return the same bytes;
conflicting operations are refused. Recorder release/replacement does not revoke
frozen history or permit adoption of an unfrozen block. The acknowledgement is metadata reconciliation
only: it neither qualifies storage nor registers an available local copy, and it
does not set archive publication fields.

### Delivering a retained intent

`ServiceRadarNVR.deliver_publication(block_id)` verifies and syncs an existing
intent, sends its exact bytes to the installed private receiver over verified
mutual TLS, then durably retains the correlated acknowledgement. One delivery
slot per replica, a thirty-second worker deadline and at most three attempts
bound the operation independently of recording and read admission. Timeout is an
unknown outcome: retry the original operation. Existing acknowledgements do not
bypass authenticated delivery; conflicts and partial records remain untouched.

Delivery is disabled unless both installed configuration and token files are
supplied. See [configuration, retry policy and limitations](../../docs/nvr-runtime.md#explicit-nvr-publication-delivery).
This is a trusted same-VM call. It neither advertises availability nor authorizes
deletion.

### Scheduling pending intents

Set `SERVICERADAR_NVR_PUBLICATION_AUTO_DELIVERY=true` to walk retained recovery
pages at boot and deliver pending intents. The default is `false`; enabling it
requires configured storage and both sender files. Each step visits one block in
the existing single delivery slot, including its thirty-second deadline. Failed
items remain on disk while the cursor advances to later work. The scan wraps and
restarts from nil after coordinator or VM loss. Matching retained acknowledgements
are skipped; unprepared and unresolved records remain untouched.

`ServiceRadarNVR.publication_delivery_status/0` reports the current cursor, active
worker flag, last outcome, consecutive failures, completed steps, successful
deliveries and next delay. These are volatile observations, not durable receipts.
When disabled or restarting it returns `{:error, :nvr_scheduler_unavailable}`.
The coordinator performs no file or network I/O and cannot queue extra workers.

Normal steps wait 1-1.25 seconds, with jittered exponential backoff after delivery,
scan or admission failures, capped below sixty seconds. See the
[runtime details and scan limits](../../docs/nvr-runtime.md#automatic-pending-intent-delivery).
Automatic delivery neither prepares new intents nor completes the local-copy
catalog, advertises playback, restarts cameras or deletes media.

### Retaining an intent acknowledgement

Trusted same-VM code passes Core's canonical response to
`ServiceRadarNVR.acknowledge_publication(block_id, bytes)`. The NVR verifies the
sealed media and retained intent, then checks that the response binds that exact
intent. It syncs the matching intent file and directory before exclusively
creating and syncing `publication-ack.json` and its directory. Both records are
retained. An exact retry syncs the same bytes without replacing either file.
Partial, conflicting, aliased or oversized records remain unresolved and intact.

Acknowledgements are bounded to 512 bytes. The write uses the same bounded task,
logical-budget and physical-free-space checks as intent preparation. Existing
exact retries need no additional byte budget; a timeout leaves an unknown outcome
that callers resolve by inspecting or retrying the same response.

`ServiceRadarNVR.publication_acknowledgement(block_id)` reads through the bounded
read pool and reverifies the original intent and media. It does not sync a
recovered file; retry the write to confirm that boundary. The codec verifies
content correlation, not Core identity. The trusted caller owns authentication;
there is no remote acknowledgement listener yet. A retained `intent_accepted`
response neither proves storage qualification nor advertises a recording, grants
playback/deletion permission, or permits discarding the original intent.

### Recovering publication work after restart

`ServiceRadarNVR.publication_page(cursor \\ nil, limit \\ 1)` reads retained
publication evidence without saved notifications. Pass each `next_cursor` back
unchanged until it is nil. Cursors bind the storage UUID and last block ID;
another storage lifetime is refused. Each page returns `storage_id`, `entries`
and `next_cursor`. Entries contain `block_id` and one of these states:

| State | Evidence returned |
| --- | --- |
| `pending` | Verified canonical intent bytes for reconciling the original delivery operation |
| `intent_accepted` | Verified intent and matching retained acknowledgement bytes |
| `unprepared` | Neither publication record was observed; this does not assert sealed or valid media |
| `unresolved` | Verification error, without delivery bytes; preserve for reconciliation |

A corrupt earlier record remains visible and does not hide later entries. A
missing intent with a surviving acknowledgement remains unresolved. Media is
reverified before returning intent or acknowledgement bytes. Unsafe inventory,
including aliases or unknown files, fails the entire page instead of skipping
evidence. Reads never repair, sync or change files, and accepted evidence does
not authorize compaction or deletion. These observations do not confirm that a
prior interrupted write reached its sync boundary. Before delivering a recovered
intent, retry `prepare_publication/2` with its exact original reference to sync
it. Likewise, retry `acknowledge_publication/2` with the exact response to confirm
the acknowledgement's durable boundary.

The limit is 1..16 entries (one by default), under the existing four read slots
and ten-second task deadline. Returned record bytes are bounded to 16 times
66,048 bytes per page; no media bytes are returned. Inventory still scans at most
4,096 block directories. A timeout returns no partial page: retry the same cursor
with a smaller limit. Failure at limit one remains unresolved work.

This is an observation scan, not a stable snapshot or a durable delivery queue.
Concurrent publication may change previously read entries, and new blocks that
sort before the cursor appear only on a new scan from nil. Preserve unresolved
work and rescan; advancing a cursor acknowledges nothing. A trusted coordinator
may explicitly deliver a pending intent with `deliver_publication/1`, or enable
the scheduler above. Core catalog completion remains separate work.

## Descriptor-bound local media reads

`ServiceRadarNVR.read_block(block_id, descriptor_sha256, selector)` returns
`{:ok, bytes}` for `:init` or `{:fragment, sequence}`. The expected digest is the
lowercase hexadecimal SHA-256 of the canonical JSON from `block_descriptor/1`.
It binds each read to that descriptor's identity, clock, format and media map.
A different digest returns `:descriptor_digest_mismatch`; malformed digests and
selectors are refused before media I/O. A missing fragment returns `:not_readable`.
Paths, arbitrary byte ranges and whole-block media reads are not accepted.

Every request re-verifies the complete sealed block under the existing 16 MiB /
8 fragment limit, compares its descriptor digest, then rechecks storage identity
and the selected bytes' hash. Initialization output is at most 1 MiB and fragment
output at most 4 MiB. Corrupt or unsealed evidence is refused without repair.
I/O runs in the bounded read pool, outside the recording capacity admission GenServer.

This is a trusted same-VM primitive, with no network endpoint. The digest is a
content binding, not playback permission or an assignment lease. Full-block
verification on every read is finite but is not a playback throughput claim.
Authenticated owner-aware delivery, downstream buffering budgets and seek
cancellation remain work for the remote playback protocol. No cache or catalog
is created by these reads.

## Read admission and lifetime

Inventory, sealed-block inspection, descriptor generation, intent inspection and media reads share
four supervised task slots per replica. A full pool returns
`:nvr_read_capacity`; media work is not queued. An unavailable/restarting pool or
failed task returns `:nvr_read_unavailable`. Invalid media selectors and descriptor
digest syntax are refused before requesting a slot.

Each admitted task has a ten-second deadline and returns `:nvr_read_timeout` on
expiry. The deadline belongs to the worker, so a dead caller cannot leave an
unbounded orphan: its task may finish or occupy its slot until the original
deadline. Late replies are discarded through a caller-owned process alias.
These are admitted-work limits, not a network request deadline or a throughput
qualification; they do not preempt kernel I/O already in progress.

Read slots are independent of recording reservations. Restarting the read
supervisor retires its admitted tasks without retiring recording workers; losing
storage/capacity accounting still retires both. No read repairs or deletes media.
Returned binaries become the caller's responsibility. The pool does not bound
buffers retained by consumers, shared caches or network egress, and supplies no
playback authorization or per-viewer fairness. Those remain remote protocol work.

## Explicit interrupted-block recovery

After retiring the previous writer and establishing exclusive volume attachment,
a trusted same-VM caller may invoke
`ServiceRadarNVR.recover_block(block_id, expected_identity)`. The expected identity
includes the original source, profile, recorder epoch, block sequence and clock
provenance. A directory name alone is insufficient. This is an explicit operation;
startup does not repair blocks or resume capture.

Recovery refuses while any local writer holds a reservation or a publication task is active. The capacity owner
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
| `SERVICERADAR_NVR_MAX_SPOOL_BYTES` | 1073741824 | 1 TiB; retained bytes, full active reservations and missing publication records |
| `SERVICERADAR_NVR_RESERVE_BYTES` | 67108864 | 1 PiB; physical free-space floor; admission also needs all reservations free |
| Inbox | 8 samples / 8 MiB per worker | charged before mailbox admission |
| Local block | 16 MiB / 8 fragments | rotate at a complete fragment boundary; no eviction or deletion |
| Fragment | 4 MiB | oversized output fails the worker |
| Read work | 4 tasks per replica / 10 seconds each | no media-work queue; separate from writers |
| VM | 2 schedulers / 32768 processes / 4096 ports | release VM arguments |
| Kubernetes | 2 CPU / 1 GiB memory per replica | configurable container limits |

These are finite runtime limits, not measured camera capacity. Storage replication,
physical I/O budgets and continuous-policy admission remain qualification work.
The default network listener only serves health probes; private media ingress is
separately opt-in:
`GET /healthz` means the runtime is live; `/readyz` additionally verifies the
configured private storage root and identity. Neither admits a recording pool.

Before starting a worker, the serialized capacity owner charges one maximum block
(init, media and journal) plus 64 KiB for its intent and 512 bytes for its
acknowledgement against both the spool budget and available disk space.
It counts existing sealed, partial and abandoned files without recovering or
deleting them. Each retained block also reserves the maximum size of each missing
publication record. Existing records are immutable: even partial/corrupt records
are charged by their actual size and cannot be repaired or replaced by retry.
Worker exit releases the media reservation, not retained bytes or missing records.
At rotation the capacity owner atomically replaces that worker's reservation
after inventorying the sealed block. There is no release/reacquire gap, and
other active reservations remain charged.
`ServiceRadarNVR.capacity/0` returns a read-only observation of usage, full active
media `reserved_bytes`, `publication_reserved_bytes` (missing retained records
plus a full allowance per active recording and any pending publication write),
`publication_write_reserved_bytes` (the pending write alone),
`publication_operations` (zero or one), `publication_block_bytes` (66,048) and
available space. It is not a promise to a future caller. Reducing the spool
budget below retained bytes plus these allowances refuses new capture; it does
not delete evidence or invalidate exact publication retries.

Inventory accepts at most 4096 block directories with the spool file names and
the optional `publication.json` and `publication-ack.json`. Unknown entries,
aliases and unreadable inventory refuse admission and
remain intact. Admission conservatively counts active bytes both as inventory
and as full reservations. It can refuse early; it cannot spend that slack on a
second worker. Losing the capacity owner retires publication tasks and recording
workers before the
replacement owner accepts reservations. Restart inventories the retained volume.

Linux hosts need GNU coreutils `/usr/bin/stat` and `/usr/bin/timeout`, supplied by
the Ubuntu image. Available space uses non-root available blocks and fundamental
block size, with a two-second probe deadline and one-second kill grace. Every
admission probes afresh; write guards reuse a pressure observation for at most one
second. Admission requires the floor plus every full reservation, including the
new block and missing publication records, to be available. After admission a
worker may consume reserved media space; write guards preserve the configured
floor plus publication headroom. This headroom stays charged when a worker exits,
then is rebuilt from inventory at successful admission/rotation or after a
publication task exits. This
can temporarily over-reserve, but never releases pending metadata space just
because a writer stopped. A failed probe or a breached floor terminates the affected worker on its
next write guard and retains provisional media. Idle workers still have their finite
deadline. This floor is an admission/stop policy, not a preallocated filesystem
partition or protection against other applications consuming the volume. The
publication allowances are logical byte bounds, not filesystem allocation or
node-loss qualification. Reserve filesystem metadata, explicit recovery and
future hold/disposition headroom when sizing the dedicated PVC.

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
refusing a successor block. It also prepares, restarts, re-reads and retries
publication intent and acknowledgement, exercises capture/rotation during a
stalled publication, deadline cleanup after caller loss and supervisor failure
isolation, and refuses conflicting, corrupt,
aliased or over-budget records. Admission and rotation retain missing-record
allowances after worker exit and release restart, and unused allowances become
available to capture only after the immutable records exist.
Core's existing
recording integration suite owns the CNPG authorization/publication contract.
Physical node-loss durability and deployed camera behavior are not established
by these synthetic tests.
