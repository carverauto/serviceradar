# VMS storage and playback design

## Existing contracts and changes from the PRD

The current `openspec/specs/camera-streaming/spec.md` specifies agent-originated
uplinks through the gateway, one Membrane relay per camera/profile, authorized
viewer sessions and bounded analysis. Its viewer-idle requirement currently
tears down upstream when viewers leave; the delta explicitly changes that rule.
Existing core camera resources and gateway forwarding remain the integration
points. A proposal or an unchecked task is not proof that recording is implemented.

The old recording and playback plans supply fencing, durable manifests,
integrity verification, authorization and deletion races. The PRD supplies the
packed-object layout and product direction. The proposed design combines both.

## 1. Media, control and observations

- CNPG/Ash owns recording policy, source/profile identity, ownership epochs,
  block index, playback authorization, holds, export jobs and current status.
- Dedicated object storage owns immutable media, initialization data, recovery
  manifests, thumbnails and derived exports. It is not the backup or warehouse
  bucket. Application indexes do not move to StarRocks.
- Recording health and analysis observations traverse JetStream/EventWriter,
  then the configured telemetry backend. GPU workers never write databases
  directly. Media bytes do not enter telemetry messages or tables.
- Existing spatial resources own camera placement and object references; Dgraph
  does not become a per-frame or segment catalogue.
- Plugins register media descriptors; long-lived native/host workers own capture,
  spool and upload. Camera credentials use the unified inventory.

## 2. Shared ingest and supported media

Maintain independent viewer, recorder and bounded analysis leases on one
camera/profile ingest. A CNPG-backed ownership epoch fences recorder mutations;
distributed process registration is discovery, not exclusive ownership proof.
A stale worker cannot publish or mutate another epoch. Acquisition, renewal,
takeover and offline edge assignment require explicit tests.

P1 starts with supported H.264 access units. Prefer native Membrane parsing and
CMAF muxing with no video decode/re-encode in the archival path. This still uses
CPU for parsing, muxing, encryption and I/O. A Boombox HLS writer is a P0 experiment,
not an assumed zero-transcode implementation. Audit its chosen pipeline.

Initial policy is continuous recording with bounded on-demand clips. Event-triggered
pre/post recording remains deferred until a sized prebuffer and its loss/retention
behavior are proved, preserving the earlier proposal's boundary.

Target roughly two-second fragments, cut at valid random-access points. Two
seconds is not a guarantee if a source has a longer GOP. Bound waiting time,
fragment bytes and block bytes independently; missing keyframes cause a visible
gap/admission stop. A block closes at the earliest duration or byte bound, and
at codec/init/clock-epoch changes. Five-to-ten-minute packing and 50-150 MB are
tuning targets, not mutually guaranteed defaults.

The MP4 plugin packages encoded video; its CMAF output needs a compatible sink.
Prove a custom packer's header/segment contract instead of concatenating arbitrary
file-watcher events. A watcher may prompt discovery, but a durable manifest and
completion protocol are authoritative.

HEVC, audio and browser support are a measured matrix. Derive codec strings from
actual configuration, never a fixed PRD string. Test H.264/AAC and supported HEVC
profiles in actual browser/device combinations. G.711 conversion to Opus/AAC is
an isolated, budgeted audio path. Unsupported audio can be disabled explicitly;
unsupported video is reported, not silently decoded on every ingest.

Capture metadata includes media PTS/DTS/timebase, source sequence, clock epoch,
UTC mapping source and uncertainty. Edge receive time alone does not establish
capture time: upstream buffering remains unknown. Prefer validated RTCP sender
mapping when present; detect wrap, skew and reconnect. Synchronized playback
reports tolerances and excludes uncertain streams from precision guarantees.

## 3. Block layout, index and live-edge reads

Each block has a stable identity: source/profile, recorder epoch and block
sequence. Store codec/init fingerprint, capture interval, clock quality, size,
digest, immutable object/version identity and a versioned bounded fragment map.
Map entries contain media and UTC timing, duration, offset, length and a
motion state that can be unknown (absence of analysis is not no motion).

An open Ash block row names the provisioned storage UUID and owner epoch, not a
node, hostname, PID, unrelated volume, or user-supplied URL. That UUID follows
the storage lifetime, as recorded in [choices.md](choices.md). The local append
file and journal are fsynced to a declared durability boundary. Publish only
complete fragments below the committed readable high-water mark. Separate
bounded read workers/ETS snapshots serve media; a packer GenServer serializes
append state, not every viewer byte. Do not rewrite the full JSONB map for each
fragment.

State is explicit:

`open_local -> sealed -> uploading -> archive_verified -> available`

`open_local` can be played through an authorized local range endpoint but is
labelled provisional. `archive_verified` means media, init and recoverable
manifest were verified; `available` additionally means the authorized central
index is published. Gaps, inaccessible local storage, deletion and failures are
separate states. Never display local-only bytes as durable archive.

The final block index may use a Timescale hypertable with bounded JSONB maps.
Choose chunk interval, overlap/time indexes and compression only after query and
update benchmarks against the shipped extension version. Holds and export leases
are ordinary transactional resources outside compressed history. Every table
has an Ash resource; schema changes use the repository migration workflow.

## 4. Publication and recovery

Upload sealed immutable blocks with bounded concurrency and persisted multipart
IDs/part receipts. Do not use an S3 multipart ETag as a general content digest.
Verify final bytes and init dependencies, publish a recovery manifest with the
fragment map/digest/provenance, then perform an idempotent fenced index transition.
Keep stable keys on retry; conflicting existing content is an error, not overwrite.

Recover at append/journal, seal, upload part, completion, checksum, manifest and
index boundaries. Restart reconciles complete local fragments and records a gap
for an incomplete tail. Node/PVC loss before archival may lose provisional media;
a local fsync is not cross-node replication. Do not claim a lossless failover.
A node-local cache miss can fall back only to a verified archive; inaccessible
unarchived data stays unavailable. Archive manifests reconstruct lost index state.

Reclaim unarchived spool only after verified recoverable archive publication or
an explicit loss policy. Bound orphan/multipart cleanup and recheck actual storage
results. The edge proposal can reclaim after its durable archive receipt while
central index delivery retries separately.

## 5. Playback, access boundaries and cache

The current [single-block playlist contract](archive-playlists.md) exposes
complete protected resources; byte offsets remain internal to the reader.
Broader timeline playback must preserve init maps, durations, sequences and
discontinuity/clock information. Each object/init
boundary resolves the correct initialization range. Offline time is represented
in the API timeline; a discontinuity tag alone does not encode wall-clock gaps
or prove a player will recover. Test seek/reconnect across real generated outputs.

Authorize timeline, manifest, every media range and export separately. A signed
S3 object URL usually grants the entire packed object, not only the fragment in
the playlist. The default is an authenticated range gateway enforcing permitted
block/range/time bounds. Direct presigned URLs are permitted only when the actor
is authorized for the whole object and the bounded expiry is acceptable.
User-controlled URLs/paths never select a local file or arbitrary upstream host.

Reauthorization, expiry, cancellation and concurrency limits apply to sessions.
Shared map/object/time links identify context and grant no access. Dashboard hide,
unmount and navigation release only viewer resources.

The NVMe cache has byte/time/read budgets, reserved recorder capacity and observed
hit/miss status. A 24-hour objective is capacity-dependent; pressure evicts verified
cached copies before unarchived spool. Timeline coverage/motion rollups must handle
late publication, gaps, retention and invalidation. Long windows use bounded
resolution; they do not expand every fragment in memory.

## 6. Holds, retention and exports

Serialize hold/export/deletion claims in CNPG. A hold is pending until verified
protected media and its manifest exist; reject holds on missing bytes. Preserve
whole packed blocks initially to avoid invalid partial MP4 copies and multipart
minimum-size problems. Track the requested interval separately from extra retained
bytes. Exact clip export is a distinct remux/re-encode job with an explicit
keyframe boundary policy.

Do not enable independent expiration that can race a newly requested hold.
The baseline uses application-coordinated deletion; provider lifecycle rules
cover safe temporary objects/incomplete uploads or a proven delayed-expiration
contract. Evidence storage has no automatic expiry. Application evidence holds
are not advertised as regulatory WORM: stronger guarantees require a validated
Object Lock policy, version-aware reads/deletion and a separately approved
retention mode. Retention-tier changes preserve the actual recorded policy;
renaming a prefix does not change an object's creation age.

Deletion moves through intent, object/version deletion, verified absence and
metadata cleanup. A delete marker alone is not physical deletion. Never drop a
Timescale chunk containing retained/held/export-dependent metadata. Preserve
audit records and recovery manifests needed by surviving media.

Exports are bounded jobs with separate output quotas, protected originals,
checksums and provenance. Branded/annotated/composited exports are derivatives;
they never replace the captured recording.

## 7. Scale and measurements

The PRD's 10,000-camera target is a synthetic scale target, not observed capacity.
At ten-minute blocks it produces about 16.7 completed blocks/s; an open INSERT
plus final UPDATE already means about 33.3 row mutations/s, before leases,
recovery, motion, holds and indexes. Packing 300 fragments into one object reduces
object count by 99.67%; multipart requests, manifests, retries and HEAD checks
mean this is not automatically a >99% reduction in billable API calls.

One sample per five seconds at that target is 2,000 inference samples/s. Bound
sampling by admission and measured GPU capacity. Size NVMe from aggregate admitted
bitrate times residence window, plus upload/recovery/failure reserves. Benchmark
database WAL/index cost, cache I/O, object operations, egress and GPU memory.

Measure p50/p95/p99 separately for timeline DB query, API response, first byte and
first decoded frame, with region/RTT, cache state, codec/GOP, concurrency, bitrate,
GPU warmup and failure load declared. PRD targets (<20 ms timeline, <5 ms aggregate,
<15 ms hot and <150 ms cold first frame, >90% compression) remain hypotheses.
P0 records attainable service objectives before product commitments.

## 8. Rollout and unresolved engineering gates

Feature off by default; provision schema/configuration without changing live-view
defaults. Roll out P1 against synthetic media before the explicitly designated
test deployment/camera. Compare source sessions, recorded bytes, checksums and
browser behavior after rollout completion. Use GPU node-pool selectors rather
than hard-coded live hostnames. Real footage, identifiers and credentials never
become fixtures, screenshots or committed examples.

Stop admission, drain/seal pending blocks and preserve archive/index/holds during
rollback. Old readers must reject unsupported manifest versions safely. No
automatic bucket deletion on disable or chart rollback.

Open P0 gates: exact pinned media versions and sink API; block/fragment bounds;
clock tolerance; extension/index choices; actual endpoint security/lock/checksum
support; supported GPU architectures/backends; safe resource envelopes and cost.
[Cloud contract](cloud-control-plane.md) and [worker contract](media-workers.md)
assign owners and validation for these gates.
