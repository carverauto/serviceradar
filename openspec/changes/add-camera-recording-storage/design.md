## Context

Build the durable segment and recording-index foundation on existing shared ingest.
Production playback/retention belongs to `add-recording-playback-lifecycle`;
JetStream buffering belongs to `add-edge-recording-archive`. A browser seek
prototype here validates the segment format, not completion of the playback UI.

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
local reclamation under `add-edge-recording-archive`; publishing the authorized central index
makes that archive available for platform playback. An unavailable central index
must not prevent draining local storage when the archive can reconstruct it.


## Rollout and format gate

Feature off by default. Add Ash migrations and storage configuration without
changing live-view defaults. Freeze segment container, duration, size and clock
quality after a synthetic H.264 seek/reconnect prototype. Stop admission before
rollback and preserve archived objects/index records for the lifecycle owner.

## Delivery and isolation

Use treehouse and remote RBE with --config=remote; no Docker, local compilation
or new shell scripts. Automated database tests use srql-fixtures scratch DB only.
All fixtures are independently invented. Use migrations for schema changes.
Run required checks and make test before a PR; deliver every PR through no-mistakes.
