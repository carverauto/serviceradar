## Context

`go/pkg/agent/camera_relay_rtsp.go` currently reads native H.264 RTSP.
`Camera.RelaySessionManager` reuses one relay per camera/profile; the camera spec
keeps live media out of plugin result JSON and supports shared analysis branches.
Recording must become a lifecycle owner even when no viewer is connected.

Existing object-store experience is reusable but not a recorder:
`FieldSurveyArtifactStore` uses a bounded NATS bucket (default 1 GiB) and can set
TTL/replicas; `NATS.StateBucketSizing` handles safe discard-new cap reconciliation.
`ColdTier.ObjectStore` implements S3 maintenance/publication operations.
Neither supplies a segmented recording timeline, continuous ingest policy, or
durable video playback. Do not copy FieldSurvey's whole-blob-in-memory API into
a continuous video recorder.

## Goals / Non-Goals

- Goals: retained, seekable video with bounded resource use; live and recording
  share source ingest; temporary staging has an explicit outage budget; gaps are
  visible; SDK consumers use stable media references and host APIs.
- Non-goals for the first slice: transcoding arbitrary codecs, audio/PTZ/ONVIF
  expansion, face recognition, legal-evidence certification, indefinite archival,
  or a replacement for the SCRITH ontology/causal engine.

## Decisions

### 1. Separate the control, observation and media paths

Plugins discover sources and emit typed inventory, telemetry/events and media
descriptors. They do not select buckets, database tables or Dgraph predicates.
Actual RTSP reads use the existing native reader or supported dedicated Wasm media
bridge, not `run_check` results or numeric telemetry envelopes. Do not require
Wasm to decode/transcode video just to register a source.

- CNPG/Ash: source/profile identity, recording policy, lease, segment index,
  retention/hold/export workflow, permissions and bounded current status.
- Object storage: immutable finalized segments, initialization data, thumbnails
  and exports. Use a media-specific bucket/prefix and lifecycle, distinct from
  StarRocks' internal object-store layout and telemetry cold-tier files.
- JetStream/EventWriter: recording health, detection and observation history;
  StarRocks when enabled, CNPG telemetry otherwise. No media bytes in those tables.
- Dgraph: useful object/camera/site relationships only; no segment catalogue or
  per-frame position/detection edge explosion.

Monitored camera credentials stay in the unified CNPG credential inventory.
Service-to-service object-store/NATS credentials follow infrastructure policy.
Browser APIs return authorized media handles, not source passwords or reusable
bucket credentials. Stable map/media links are references, never access grants.

### 2. One upstream source, independent recorder and viewer leases

Extend the existing camera/profile relay ownership model with recorder leases.
Recording continues without viewers; closing the last viewer does not close an
active recorder. A recorder/analysis failure is isolated from live playback.
Initially segment the supported H.264 stream without mandatory transcoding.
Segments are independently seekable at keyframes, with initialization/codec
configuration references, byte bounds and a maximum duration. A source that never
provides a suitable keyframe produces a visible unsupported/gap state, not an
unbounded segment. Codec changes/reconnects create explicit discontinuities.

Use a single fenced recorder owner per source/profile; failover cannot publish two
owners' overlapping segments as one seamless stream. Capture timestamps need an
explicit clock mapping/quality: RTP timestamp wrap, reconnect and missing wall-clock
mapping must not create invented absolute times. Store source, recording, segment,
capture interval, sequence/epoch, codec, size and digest in the index.

First implementation targets continuous recording and bounded on-demand clips.
Event-triggered pre/post recording reuses a sized prebuffer and ships only after
its retention and loss behavior are proven. Codec/container/player compatibility
is a prototype gate: prefer keyframe-aligned fragmented MP4 with a manifest-based
browser player if the existing H.264 access-unit path supports it; freeze the
format after real browser seek/reconnect proof, before publishing its API.

### 3. Durable publication is a recoverable state machine

The recording index distinguishes `pending`, `staged`, `uploading`, `available`,
`gap`, `deleting` and `deleted` (exact Ash action names are implementation detail).
Stream finalized segments using bounded buffers. Verify final object length and
content digest before an atomic index transition makes it available. A temporary
staging acknowledgement is never reported as archived. Keep an immutable object
key and idempotency identity across retries; don't append a duplicate timeline entry.

After a crash, reconcile verified objects with pending index entries and recover
unfinished uploads; garbage-collect orphaned objects/multipart uploads after a
grace interval. Delete staged bytes only after verified archive publication, or
after explicit expiry/loss policy records a gap. If metadata is temporarily
unavailable, don't claim durability or discard the only recoverable copy.
There is no cross-store transaction; idempotent transitions and reconciliation
provide recovery, with failure-injection tests at each boundary.

For disconnected edges, `archived` and globally `available` are separate facts.
Verified S3 media plus its recoverable archive manifest and durable receipt permit
local reclamation as described below; publishing the authorized central index
makes that archive available for platform playback. An unavailable central index
must not prevent draining local storage when the archive can reconstruct it.

### 4. JetStream staging is optional, finite and admission-controlled

The direct media profile uploads finalized segments to durable object storage
using a bounded local spool. The disconnected-edge profile uses a local JetStream
Object Store as its finite transfer buffer, with the capture process, local NATS
server and archiver all able to run without the hub. Both profiles are part of
this proposal; disconnected capture is an explicit acceptance gate rather than
an inferred benefit of core-side staging. Operators choose the profile and budget.

When JetStream staging is enabled, require nonzero TTL, finite max bytes, maximum
object/segment size, bounded upload concurrency, replica count, placement and
per-deployment total media budget. Use dedicated buckets and reserve space/IOPS
for telemetry; separate buckets on the same disks alone do not provide isolation.
Reuse safe discard-new sizing rules rather than silently evict chunks belonging
to still-needed objects. A full bucket rejects admission; it is not proof of an
accepted complete segment. Interrupted chunk uploads and expiry are reconciled.

The upload deadline is earlier than the oldest segment chunk's expiry by a safety
margin that covers upload/retry duration. Immutable segment objects are never
rewritten to extend TTL indefinitely. Emit oldest-unarchived age, pending bytes,
remaining capacity, upload throughput/failures and lost capture intervals.
At high water, reduce/admit fewer recordings according to explicit policy; at
exhaustion, stop admitting affected recordings and expose gaps. Never expand the
bucket automatically, evict telemetry, or label unarchived footage as retained.
Disabling staging drains or explicitly disposes of pending segments before teardown.

### 4a. Disconnected edge capture and continuous archival

Deploy local JetStream with persistent disks and an explicit domain/account
binding. A leaf connection joins messaging domains; it does not turn a disconnected
edge server into a member of a remote Raft group, automatically replicate an Object
Store bucket, or upload anything to S3. Local recording clients and the archiver
must explicitly bind to the local JetStream domain and bucket. They must not need
remote quorum or a central CNPG connection to finalize a local segment.

The flow is:

```
local RTSP source -> edge recorder -> completed local JetStream objects
                                      -> edge archiver -> permanent S3 objects
                                                       + recoverable manifests
                                      -> durable metadata delivery -> core index
```

The plugin registers/normalizes the source through the existing host interfaces;
the native media worker or dedicated Wasm media bridge supplies media. A long-lived
host recorder and archiver own buffering/upload state, outside the stateless
per-check Wasm execution. Reuse the existing recorder identity/lease and durable
edge-record provenance contracts rather than adding a second plugin transport.

1. Before disconnect, provision an authorized recording assignment, local storage
   policy and a finite offline operating window. Recorder ownership is fenced
   locally; policy/credential expiry is an observable stop condition. Do not
   require a fresh central lease round-trip for every captured segment. Bind
   capture provenance to the policy/owner epoch so later upload can be validated.
2. Finalize a bounded keyframe-aligned segment locally; verify complete object
   storage and append its immutable identity to a durable pending-work journal.
   The complete-object catalogue plus journal reconciliation repairs a crash
   between these steps. Object-store watch events alone are not a durable queue.
3. The archiver starts work as soon as a segment is complete, not when a recording
   session closes or a staging high-water mark is reached. It tests S3 reachability
   independently of leaf status: if S3 is reachable while the hub is not, upload
   continues. Use bounded concurrency, bandwidth budgets and jittered retries.
   Oldest safe-deadline work gets priority; retry state survives process restart.
4. Upload under a stable object identity. Resume multipart state where supported,
   or retry a bounded segment; reconcile completed uploads before retransmission.
   Verify byte length and content checksum (an ETag is not generally a content
   checksum), then persist and verify an immutable archive manifest containing
   source/policy epoch, time mapping, codec/init references, digest and object key.
   An existing matching object/manifest is success; a conflicting one is an error,
   not an overwrite. Initialization objects must be archived before dependent
   media is eligible for local reclamation.
5. Durably record the archival receipt locally and enqueue index publication.
   Local media bytes may be deleted after verified media plus a recoverable
   archive manifest exist; do not wait for the core database to reconnect. Keep
   receipt delivery retryable, and make the S3 manifests sufficient to reconstruct
   missing index entries if the local node is lost after reclamation. Central
   playback remains unavailable until authorization/index publication catches up;
   local state distinguishes archived-but-not-indexed from globally available.
6. When the leaf reconnects, reconcile receipts and publish idempotent core index
   updates over the authorized metadata path. A leaf reconnect or a JetStream
   PubAck alone never proves S3 archival. Optional NATS stream sourcing/mirroring
   is a separately configured transport choice with tested subject permissions;
   it is not required to copy video through a central NATS disk before S3.

During an offline interval, capture consumes the configured local byte/time
budget. Several hours of recording requires several hours of measured capacity,
not a minutes-long TTL. TTL is a final bound, not the normal eviction schedule:
successful archiving reclaims objects promptly. Admission requires that the oldest
unarchived segment can survive the promised offline window plus catch-up/safety
margin, or the deployment must explicitly accept a shorter coverage window.
If the link returns slower than capture produces data, backlog cannot drain;
show estimated time-to-full and the policy-selected reduced admission or stop.
Telemetry and control retain reserved bandwidth/storage during catch-up.

Expose captured, locally staged, uploading, archived-but-not-indexed, globally
available and gap intervals separately. Measure effective archive goodput,
oldest-unarchived age, backlog bytes, drain ETA, storage headroom and expiry risk.
Capture never claims unlimited disconnected retention or unqualified losslessness.
Offline credential refresh/revocation and policy-expiry behavior must be tested;
credentials for S3 are infrastructure credentials scoped to the assigned media
prefix, never a new camera-secret store inside a plugin.

NATS [cross-domain leaf and stream-source documentation](https://docs.nats.io/reference/2.12/jetstream/cross-account-subjects)
describes explicit domain addressing and permissions. Freeze deployment configs
against the installed NATS/client versions; do not depend on undocumented automatic
Object Store mirroring or on features from a newer server release.

### 5. Size storage from bitrate, outage budget and replication

All numbers below are invented planning examples, not measurements or defaults.

Let `R = sum(admitted peak bitrates) / 8` bytes/second, `W` be the maximum staging
window in seconds, `H` a measured overhead/headroom factor, and `N` replicas:

- logical staging cap must cover at least `R * W * H`, plus bounded in-flight
  partial uploads/metadata not already included in the measurement;
- aggregate physical reservation starts at `logical cap * N`, then adds node
  failure/rebuild headroom and separately reserved non-media storage;
- each placement node needs sufficient capacity for the replicas it hosts; an
  aggregate sum alone does not establish that placement or failover is possible;
- sustained archival throughput must exceed `R`; recovering backlog `B` within
  deadline `T` needs at least `R + B/T` archival throughput;
- retained bytes start at `R * retention_seconds`, adjusted for measured recording
  duty cycle, audio/metadata, object overhead and exports/holds. Do not assume
  compression savings for already compressed H.264.

Example: 24 sources at 3 Mbit/s total 9 MB/s. Thirty minutes is 16.2 GB logical
payload. With 30% headroom, plan 21.06 GB logical and 63.18 GB at three replicas,
before failure reserves and other streams. Seven continuous days are 5.4432 TB of
payload in archival storage. This is why short staging and recording retention
are separate controls. Variable-bitrate peaks, replica traffic, read concurrency,
object request rate and disk/network throughput must also pass admission sizing.

Upstream [NATS ObjectStoreConfig](https://github.com/nats-io/nats.go/blob/main/jetstream/object.go)
exposes TTL, MaxBytes and Replicas; defaults do not impose expiry or a byte cap.
Its object-store stream construction uses discard-new. Verify the installed
server/client behavior, including partial-object expiry, in the acceptance target.

### 6. Playback, retention and holds have explicit outcomes

Expose a bounded timeline with recorded intervals and gaps, seekable playback,
and authorized time-range export. Recheck authorization when issuing short-lived
playback URLs/handles; persist neither source secrets nor signed URLs in share
links. Dashboard SDK hosts own these operations and clean up players/sessions.
Camera identity links to the same optional object identity used by map providers.

Retention deletes only eligible published segments after checking holds and active
export leases. A hold racing deletion must resolve atomically in the metadata
workflow; a hold is accepted only after durable storage policy can honor it.
Never promise a hold on JetStream-only staged bytes or bytes already deleted.
Storage lifecycle rules must not delete protected media behind the application's
back. Record deletion intent, remove objects, then verify absence and mark deleted;
retry partial failures. Playback displays gaps/expired intervals honestly.

## Migration Plan

Feature off by default. Add Ash resources/generated migrations and operator
storage configuration without changing live-view defaults. First prove one
synthetic source through record/seek/restart/delete, then bounded concurrency,
then disconnected local JetStream capture plus continuous S3 drainage, then
dashboard playback and event clips. The disconnected-edge profile is not enabled
until its local-only admission, replay and reclamation gates pass.
Disable new recording admission before drain/rollback; preserve indexed available
media until its authorized retention lifecycle completes.

## Risks / Trade-offs

- Video competes with telemetry: explicit admission, measured IO/network budgets,
  placement and high-water behavior are acceptance gates, not post-release tuning.
- Browser codec support and source clock quality vary: prototype/freeze supported
  formats and present unsupported codecs or uncertain timing explicitly.
- Source disconnects and finite buffers lose footage: expose capture gaps and
  configured outage coverage rather than claiming lossless recording.

## Open Questions

- Freeze segment duration/container and playback transport after the H.264
  prototype; initial scope need not imply H.265/audio support.
- Select deployment-specific retention, peak rates and staging budget during
  installation; there is intentionally no universal recording capacity default.
