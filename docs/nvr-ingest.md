# Private NVR recording input

The first operator-test milestone is one existing inventory camera recorded by
`serviceradar-nvr`, retained on Longhorn-backed storage, listed and playable in
the UI, followed by restart and approved worker-loss verification. Two replicas
retain separate storage identities; the storage provider owns replication.
S3 remains optional.

| Milestone boundary | Current evidence | Remaining integration |
| --- | --- | --- |
| Camera to NVR | Bounded relay-to-NVR coordinator and [continuous recorder](#continuous-recording) stream a shared relay session into a configured NVR replica over mTLS | Automatic pool assignment across NVR replicas and real-camera acceptance |
| Footage catalog | [Bounded capture registration](#bounded-relay-coordinator) and durable publication intents with Core acceptance | Reconciliation of missed registrations, current-history completion and qualified local-copy registration |
| Playback | [Playback read listener](#playback-read-listener), owner-routed local timeline playback in web-ng, and [per-request isolated archive reader](archive-init-storage.md#separate-archive-reader-installation) (D.2) | End-to-end local-to-archive playback verification |
| Worker replacement | Synthetic release restart preserves decoded frames | Deployed Longhorn attachment and approved node-loss verification |

The listener below closes the network input boundary. It remains disabled by
default and does not implement the coordinator or change deployment readiness.

## Installation

Set both `SERVICERADAR_NVR_INGEST_CONFIG_FILE` and
`SERVICERADAR_NVR_INGEST_TOKEN_FILE` to installed workload credential files.
Omitting both leaves the listener absent; partial or invalid configuration
refuses application startup. The token is 32 through 512 printable ASCII bytes,
without a trailing newline. Use a separate token for this purpose.

The configuration is one JSON object with exactly these fields:

| Field | Meaning |
| --- | --- |
| `port` | Private HTTPS port, integer 1 through 65535 |
| `cert_file` | Absolute path to the NVR server certificate |
| `key_file` | Absolute path to its private key |
| `ca_file` | Absolute path to the trusted client CA bundle |
| `client_sha256` | Lowercase hexadecimal SHA-256 of the permitted coordinator's DER leaf certificate |

Configuration is loaded at boot. Rotate by replacing and retiring the listener;
changing a mounted file alone does not revoke an existing process. Workload
credentials belong to infrastructure custody. Camera credentials stay in the
unified CNPG credential inventory and never enter this request.

TLS requires a trusted client certificate; the leaf pin and exactly one
`Authorization: Bearer <token>` header are checked before reading the body.
The client must verify the NVR hostname and certificate against its installed CA.
The listener supports one request per HTTP/1 connection, disables HTTP/2 and uses
two acceptors with eight connections per acceptor. Recording capacity remains
bounded separately by the existing session and disk admission limits.

The listener is private to the trusted recording coordinator or a local media
bridge. It is not a browser endpoint or a new inbound requirement from Cloud
into a customer network. When `nvr.ingest.enabled` is set in Helm, only the
headless NVR Service and a `serviceradar-core` pod-selected NetworkPolicy rule
expose the listener inside the cluster; no public route is created.

## Bounded relay coordinator

`ServiceRadarCoreElx.CameraRecording.NVRCapture` (`once_source/4` and
`once_relay/3`) runs one finite capture from the shared camera relay into a
configured NVR replica without opening a second direct camera RTSP stream or
sending media over NATS/JetStream or ERTS distribution:

1. `once_source/4` reuses an active shared relay or opens one via
   `RelaySessionManager.request_open/3`, then routes execution to the `core-elx`
   node hosting `CameraRelay.Pipeline` (`ServiceRadar.Camera.RelayHosts`).
   It refuses with `:recording_disabled` before opening anything when the
   recording supervisor is off. If capture fails before streaming starts, or
   the NVR refuses the stream, it closes the relay only when this call opened
   it; a reused relay, including one a live viewer is still opening, is left
   untouched.
2. `NVRTargetConfig` resolves installed workload mTLS/token credentials and the
   target replica's provisioned `storage_id` from
   `SERVICERADAR_NVR_CLIENT_CONFIG_FILE` and
   `SERVICERADAR_NVR_CLIENT_TOKEN_FILE`.
3. `NVRWorker` verifies `IngestOwnership`, acquires `RecorderOwnership` bound to
   that `storage_id`, reserves `block_sequence: 0`, attaches a bounded
   `ServiceRadarRecording.Inbox` to the relay pipeline outside live-view and
   control processes, and streams contiguous 90000 Hz H264 AnnexB access units
   through `ServiceRadarNVRClient.send_recording/4`.
4. A verified `sealed_local` receipt returns the correlated `recording_block_id`
   and `block_key`. While it holds its recorder claim, the worker reads the
   block's canonical descriptor (`GET /v1/blocks/<block_id>/descriptor`) and,
   under that still-live claim, freezes it on the `RecordingBlock` and creates
   the block's `RecordingCatalogEntry` in one transaction
   (`RecordingBlocks.freeze_and_catalog/6`). The entry's archive state follows
   the camera's `CameraRecordingPolicy` storage mode and the archive settings.
   A capture without a policy has no archive obligation. When the resulting
   entry has `archive_state: :pending`, `NVRWorker` best-effort enqueues
   `ArchiveBlockJob` on the `nvr_archive` queue. The timeline uses the
   [received time basis](docs/camera-recording.md#coverage-bar-time-basis-and-playback-controls).
   The receipt reports `catalog: {:registered, entry_id}` when the freeze returns
   success and `{:unregistered, reason}` for a definite refusal. An expired
   capture deadline or a recovery closure observed during renewal skips
   registration. Each step needs at least 250 ms within both the capture
   deadline and the lease time left after reserving cleanup time.
   If the registration task times out
   or Core cannot confirm the freeze, the receipt reports `{:unconfirmed, reason}`.
   The transaction may have committed. The NVR seal remains durable in every case.
   Core attempts claim release and relay close, then returns `{:ok, receipt}`
   with `release: :released` or
   `release: {:release_pending_lease_expiry, reason}`. A failed release logs
   a warning, and lease expiry permits takeover. Without a verified seal, an
   unknown transport outcome, timeout or caller loss stops the stream, never retries
   or fails over to another replica, and leaves the reserved block and epoch
   intact for inspection or recovery. The recorder lease keeps renewing until
   the NVR answers. These uncertain outcomes return
   `{:error, {:nvr_ingest_uncertain, details}}` and keep the recorder fence
   until its lease lapses.
5. An NVR that answers 400, 401, 422 or 503 before the end marker was sent has
   refused the unfinished stream and sealed nothing it had open. That is a
   definite failure, not an unknown outcome: the capture returns
   `{:error, {:nvr_ingest_refused, %{status: status, ...}}}` with the same
   correlation fields and attempts to release its recorder claim. Successful
   release lets the next capture of the source start immediately. Its reserved
   `RecordingBlock` stays `:open_local`. A non-200
   answer read after the end marker stays uncertain, because the NVR can
   answer 422 or 503 after it has sealed.
6. Core can stop a stream itself: a unit that fails order validation (for
   example `:non_monotonic_timestamp` when a relay delivers a backwards
   timestamp), a failed relay drain, a stopped relay pipeline or a failed
   fence renewal. The client sends the end marker only after the worker hands
   its sender `:eof`, so a Core abort before that point cannot have requested
   a seal. It is a definite failure: the capture returns
   `{:error, {:nvr_ingest_aborted, %{reason: reason, ...}}}` with the same
   correlation fields and attempts to release its recorder claim, as for a
   refusal. Without a verified receipt, a Core abort after the worker handed out
   `:eof` stays uncertain because the end marker may have gone out. A capture
   timeout or caller loss also stays uncertain in the absence of a verified receipt,
   even when Core stops the stream before `:eof`.
   `frames_sent` and `bytes_sent` count units handed to the NVR client, so
   after a failure they bound from above what reached the NVR.
7. A capture `timeout_ms` outside 1 through 300000 is refused before any
   recorder claim is taken. A capture with less than 250 ms left before its NVR
   stream opens stops with `:capture_timeout` (not uncertain) and attempts to release its
   recorder claim. A verified receipt is returned even if worker cleanup
   outlasts the drain window.

A capture ends at the first of its frame, byte and media-duration bounds
(defaults 240 frames, 8 MiB and 6 seconds; ceilings 8,100 frames, 12 MiB and
270 seconds, about 4.5 minutes at 30 fps). The call's `timeout_ms` must cover
the capture, relay start-up, the NVR seal and the block's registration: about
295,000 ms for a 270-second capture. The NVR side must allow the same: `nvr.maxDurationMs` defaults to
300000 in the Helm chart for this reason.

One capture is one NVR block, `block_sequence: 0`, and the worker accepts only
a receipt naming exactly that block. The 12 MiB byte ceiling stays below the
16 MiB block. A fragment ends at the first keyframe after two seconds, so a
270-second capture is about 136 fragments, within the NVR's default
`nvr.maxBlockFragments` of 150. A fragment can be shorter than two seconds by
up to one frame interval when a keyframe falls just before the two-second mark
and its duration crosses it; streams with frequent keyframes and gaps after them
(dropped frames, variable frame rate) can make many such fragments. If a
capture ever needs more fragments than the NVR's limit, the NVR rotates into a
second block, the receipt names two blocks, and the worker reports the outcome
as uncertain: both blocks stay sealed on the NVR, but Core records neither as a
completed capture. Keep `nvr.maxBlockFragments` at 150 or more while Core
captures run at the 270-second ceiling.

## Continuous recording

`SERVICERADAR_CAMERA_RECORDING_ENABLED` (rendered from the Helm chart value
`nvr.ingest.client.cameraRecordingEnabled`) is the single canonical switch
enabling continuous recording in `core-elx` for cameras whose
`CameraRecordingPolicy` has `mode == :continuous`. When enabled (and the
database repo is enabled and durable `RecordingControl` stop is not active),
`ServiceRadarCoreElx.CameraRecording.ContinuousManager` reconciles all
`mode == :continuous` policies and supervises one
`ServiceRadarCoreElx.CameraRecording.ContinuousRecorder` per
`(camera_source_id, stream_profile_id)` pair. Cameras without a `:continuous`
policy remain unaffected.

Each continuous recorder holds one `RecorderOwnership` claim and one bounded
`ServiceRadarRecording.Inbox` per run, performs keyframe-aligned block handovers
at soft targets (`260,000 ms`, `7,800` frames, `10 MiB`) within the hard
ceilings (`270,000 ms`, `8,100` frames, `12 MiB`), resolves uncertain outcomes
through `POST /v1/blocks/lookup`, catalogs each sealed block before releasing
the claim, and enqueues `ArchiveBlockJob` when required by policy.

## Finite stream contract

Send `POST /v1/recordings/ingest` with exactly one
`Content-Type: application/vnd.serviceradar.nvr-ingest.v1` header. HTTP
Content-Length and chunked transfer are supported. HTTP chunk boundaries do not
need to align with application records. All integers below are unsigned network
byte order (big endian).

1. A four-byte header length, from 1 through 1024, followed by canonical JSON:
   sorted object keys, compact encoding, no duplicate or unknown keys. The
   header has `version: 1`, `storage_id`, `recovery_generation`, `clock_epoch`
   and `identity`. The identity has `source_id`, `profile`, `recorder_epoch`
   and `block_sequence`, using the existing recording identity limits.
2. Each access unit has a four-byte payload length from 1 through 1048576,
   then eight-byte `sequence`, `pts` and `dts` values, then that many payload
   bytes. Payloads are complete H264 AnnexB access units. The existing writer
   validates the H264 profile, keyframe acquisition, timestamp and sequence
   continuity. Baseline and constrained-baseline streams are accepted. Main and
   High streams are accepted only when every sequence parameter set rules out
   frame reordering, by picture order count type 2 or a declared reorder depth
   of zero. Timestamps use a 90000 Hz timebase with no frame reordering. UTC
   mapping is explicitly unknown; receipt time is not capture time.
3. A zero four-byte payload length terminates the application stream. It must
   be followed immediately by HTTP body completion. Truncation, extra bytes or
   an HTTP EOF without this marker do not request a seal.

The header's storage UUID and recovery generation must match this NVR's installed
configuration. The coordinator supplies the original source/profile, recorder
epoch, block sequence and clock epoch from its authorized capture operation.
These fields are correlation, not proof of ownership: the installed coordinator
must establish exclusive source/writer assignment and valid authority covering
the finite operation before sending it. This transport does not enroll a pool,
issue leases, resolve an uncertain earlier writer or authorize takeover.

One request admits at most 64 MiB of application body and reports at most 256
sealed blocks. Reads have a 15-second timeout. The existing configured session
duration also bounds the entire request handler, including body reads and
sealing; the service default is 30 seconds, the Helm chart sets five minutes
(`nvr.maxDurationMs: 300000`) and the ceiling is five minutes. The timer
survives a stalled or disconnected caller. There is no renewal or implicit retry.
The producer waits for each frame to pass through the writer before admitting
the next; this wait must stay outside shared live-view and control processes.

## Sending client

`ServiceRadarNVRClient.send_recording/4` in `elixir/serviceradar_nvr_client`
implements this finite stream contract without a Core, database, Membrane or NVR
application dependency. Its caller supplies an installed endpoint, workload
credentials, an authorized recording identity and a lazy access-unit enumerable.
The client pulls and sends one frame at a time, enforces unit/body/response
limits, verifies the server identity, and bounds the producer and socket lifetime
even after caller loss. Only normal enumeration completion sends the end marker.
It never retries, follows redirects or selects another replica.

A success receipt must match the requested storage lifetime and consecutive
block keys. Transport or malformed-response failures return an unknown outcome
requiring discovery at the original NVR.

The NVR answers a refused stream at once and stops reading the body, while the
client may still be sending. So before sending each chunk up to and including
the end marker, the client polls the connection without blocking. If an answer
has started, it sends nothing more, reads the rest of that answer within the
same deadline and size limits, and returns `{:error, {:ingest_refused, status}}`
for a complete non-200 answer. After a failed send it makes one non-blocking
read for an answer already received. A non-200 answer read after the end marker
returns `{:error, {:ingest_status, status}}` instead, because it does not rule
out a seal. A 200 before the end marker, or an answer that is lost, cut short or
malformed, is `:outcome_unknown`. See the [client API and configuration](../elixir/serviceradar_nvr_client/README.md).
This is a library for the media bridge; installing it enables no consumer. The
[bounded relay coordinator](#bounded-relay-coordinator) and
[continuous recorder](#continuous-recording) are its callers and perform source
ownership and recorder admission before sending.

## Outcomes and preservation

HTTP 200 returns `version: 1`, `status: sealed_local`, the `storage_id` and
ordered `block_ids`. IDs are opaque 64-character lowercase hexadecimal values,
not paths. This response confirms local seals only. It is not qualification,
Core publication, a playable catalog entry or permission to delete footage.
Existing block discovery is needed after an unknown response outcome.

Authentication failures return 401, malformed headers return 400, unavailable
admission returns 503 and incomplete media returns 422. A deadline, broken
transport or process failure can close the connection without a JSON response.
Any lost response is an unknown outcome. Do not automatically resend media,
change the recorder epoch or move to another replica to hide that uncertainty.

An answered refusal is not an unknown outcome. The NVR seals the final block
only after it reads the end marker and HTTP body completion, so any of these
statuses received before the end marker was sent means the block it had open
was not sealed; its journal is kept unsealed. The coordinator treats that as a
definite failure and attempts to release its recorder claim. The same statuses can arrive
after the end marker following a seal: a 503 when recovery closes after
sealing, or a 422 when sealing outlasts the deadline. Those stay unknown.

A stream the coordinator stops before it releases the end marker is not an
unknown outcome either: without the marker the NVR seals nothing it had open,
whatever the transport reports. The coordinator treats that as a definite
failure and attempts to release its recorder claim. Once the end marker may have gone out,
a coordinator-side stop, timeout or caller loss leaves the outcome unknown until
Core receives a verified seal receipt for its reserved block. A verified receipt
completes the capture and Core attempts claim release even if registration is
refused.

| When the stream ended | What Core knows | Capture result | Recorder claim |
| --- | --- | --- | --- |
| Verified `sealed_local` receipt naming the reserved block | Sealed | `{:ok, receipt}` | Release outcome on receipt |
| NVR answered 400, 401, 422 or 503 before the end marker | Open block not sealed | `{:error, {:nvr_ingest_refused, details}}` | Release attempted, expiry on failure |
| Core stopped the stream before handing out the end marker | Open block not sealed | `{:error, {:nvr_ingest_aborted, details}}` | Release attempted, expiry on failure |
| Core stopped after the end marker, without a verified receipt | Unknown | `{:error, {:nvr_ingest_uncertain, details}}` | Held until the lease lapses |
| Capture timeout without a verified receipt | Unknown | `{:error, {:nvr_ingest_uncertain, details}}` | Held until the lease lapses |
| Caller loss without a verified receipt | Unknown | `{:error, {:nvr_ingest_uncertain, details}}` | Held until the lease lapses |
| Answer lost, cut short, malformed, or non-200 after the end marker | Unknown | `{:error, {:nvr_ingest_uncertain, details}}` | Held until the lease lapses |

A refused or aborted capture with the recovery gate closed is reported as
uncertain and keeps its claim.

Incomplete work retains its journal and completed blocks. A stream longer than
one block seals each full block as it goes. If a capture rotates before a
later refusal or Core abort, the NVR leaves the earlier block sealed while
Core attempts to release the recorder claim. The NVR reports blocks sealed mid-stream only
in a 200 receipt, so Core does not learn that block's ID; find it with block
discovery at that NVR. The request never repairs, deletes or adopts retained
storage. It cannot bypass current recovery state, the bootstrap/history
barrier, source/profile exclusion, capacity checks or write-time disk guards.
Closing recovery during work withholds success even if some bytes have already
been written. Inspection and explicit recovery remain separate operations under
their existing authority requirements.

## Block descriptor

The same authenticated listener answers `GET /v1/blocks/<block_id>/descriptor`
with the canonical v1 descriptor JSON of one sealed block: its identity and
clock, codec, initialization and media lengths and SHA-256, and every fragment's
offset, length, timing and SHA-256. Core freezes exactly these bytes when it
catalogs the block. The read runs in the NVR's shared read pool (four slots, no
queue, ten seconds per read), verifies the whole sealed block before answering
and changes nothing on disk. Answers: 200 with the descriptor bytes, 401 for a
client that fails the certificate pin or token, 404 `block_not_found` for an ID
that names no retained block (including a malformed ID), 409 `block_not_sealed`
for a block with no seal that verifies, and 503 `descriptor_unavailable` when
the read pool is full, the read times out, recovery is closed or storage is
unavailable. The request deadline is 15 seconds.

## Member status and block state

The ingest listener, with the same pin and token, answers three bounded
observations that Core's recording coordinator and reconciler use. They change
nothing on disk. Each request is bounded by 15 seconds.

- `GET /v1/status` answers 200 with `version`, `storage_id`, `recovery`
  (`state` `ready` or `closed`, and the pinned `generation`), `inventory`
  (`ready`, `rebuilding`, `mismatch` or `unavailable`), `capacity` (`used_bytes`,
  `max_spool_bytes`, `available_bytes`, `reserve_bytes`, `reserved_bytes`,
  `reservations`, `blocks`, `max_blocks`; null unless the block ledger is ready
  or mismatched), `max_sessions`, `archive_busy` and `release`. A closed gate or
  an unbuilt ledger is reported, not refused.
- `POST /v1/blocks/lookup` with exactly one
  `Content-Type: application/vnd.serviceradar.nvr-lookup.v1+json` header and a
  JSON body `{"block_ids": [...]}` of 1 through 50 distinct 64-character block
  IDs, at most 8 KiB. 200 lists one entry per ID, in order.
- `GET /v1/blocks?after=<block_id>&limit=<1..100>` pages the block ledger in
  ascending ID order (`limit` defaults to 100). 200 adds `next_after`: the last
  ID when the page is full, null on the last page. Blocks created behind the
  cursor appear on the next walk. 503 `inventory_rebuilding` (with
  `retry-after: 1`) while the ledger is built.

Each block entry has `block_id`, `state`, `writing` (an admitted writer holds
the block now) and `bytes` (charged on disk; null when absent or unmeasurable),
plus `descriptor_sha256` exactly when `state` is `sealed` and `reason` (an error
class) exactly when it is `unresolved`:

| `state` | Meaning |
| --- | --- |
| `sealed` | The journal holds a seal record and the file lengths match it |
| `incomplete` | A valid journal without a seal record |
| `unresolved` | The directory exists but its files or journal cannot be read as a block |
| `reclaimed` | A committed tombstone exists in `.disposition-journal` for this block |
| `absent` | No directory and no tombstone; not proof the block never existed |

The state is read from the block's per-record digested journal and file lengths,
not from its media, so a lookup or page stays cheap. `sealed` therefore does not
mean the media verifies: fetch the descriptor, which verifies the whole block,
before freezing it. Lookups and pages run in the shared read pool, so 503
`lookup_unavailable` or `inventory_unavailable` (with `retry-after: 1`) means a
busy pool or a closed recovery gate. Malformed requests answer 400
`invalid_lookup_request` or `invalid_inventory_request` before any read.

The client functions are `ServiceRadarNVRClient.status/2`, `lookup_blocks/3`,
`block_page/4` and `reclaim_block/4`.

## Local block reclaim

`POST /v1/blocks/<block_id>/reclaim` on the same authenticated ingest listener
reclaims one verified sealed local block. Send exactly one
`Content-Type: application/vnd.serviceradar.nvr-reclaim.v1+json` header and a
canonical JSON body of at most 8192 bytes with `version: 1`, `storage_id`,
`recovery_generation`, `operation_id` (canonical UUID) and
`expected_descriptor_sha256` (lowercase 64-character hex).

The NVR refuses active or publishing blocks (409 `block_active`), unsealed
blocks (409 `block_not_sealed`), descriptor digest mismatches (409
`descriptor_mismatch`), unknown blocks (404 `block_not_found`), malformed
requests (400 `invalid_reclaim_request`) and closed recovery or unavailable
storage (503 `reclaim_unavailable` with `retry-after: 1`). Before unlinking the
block directory, the NVR appends and fsyncs a canonical JSON tombstone to
`.disposition-journal` at the spool root, then unlinks the block directory and
removes it from the capacity ledger immediately. Exact retries with the same
`operation_id` and `expected_descriptor_sha256` return 200 with the same
receipt; a different `operation_id` returns 409 `reclaim_conflict`. On restart,
the NVR loads `.disposition-journal`, completes any tombstoned unlinks left
behind by a crash, and reports tombstoned blocks as `reclaimed` in lookup.

## Playback read listener

A separate, opt-in HTTPS listener serves recorded media to web-ng for timeline
playback of local copies. It has its own port, client certificate pin and
read-purpose bearer token (`SERVICERADAR_NVR_READ_CONFIG_FILE`, same 5-key
format as the ingest config, and `SERVICERADAR_NVR_READ_TOKEN_FILE`). The NVR
refuses to start when the read installation shares the ingest port, pin or
token, so a playback credential can neither record nor archive and an ingest
credential cannot read media.

- `GET /v1/blocks/<block_id>/init?descriptor_sha256=<hex>` answers the block's
  initialization bytes.
- `GET /v1/blocks/<block_id>/fragments/<n>?descriptor_sha256=<hex>` answers
  fragment `n`, its descriptor `sequence`.

Each read verifies the whole sealed block, requires its canonical descriptor's
SHA-256 to equal the one given (the digest Core froze when it cataloged the
block), and rechecks the selected bytes against their journal digest. Paths,
offsets and ranges are never accepted. Answers: 200 `application/octet-stream`;
400 `invalid_read_request` without exactly one well-formed `descriptor_sha256`;
401 for a client that fails the read pin or token; 404 `block_not_found` or
`fragment_not_found`; 409 `block_not_sealed` when no seal or selected digest
verifies, or `descriptor_mismatch` when the block on disk is not the cataloged
one; 503 `read_unavailable` with `retry-after: 1` when the playback read pool is
full, a read times out or the recovery state refuses it. Reads run in their own
pool (`SERVICERADAR_NVR_PLAYBACK_READ_SLOTS`, default 8, 1 through 64, ten
seconds each), so playback cannot take the four slots that inventory, archive
and descriptor reads share. Nothing is queued and nothing on disk changes; each
request is bounded by 15 seconds.

web-ng reads through `ServiceRadarNVRClient.read_block/6` with a member map
(`SERVICERADAR_NVR_READ_CLIENT_CONFIG_FILE`, `SERVICERADAR_NVR_READ_CLIENT_TOKEN_FILE`;
the `ServiceRadarNVRClient.Members` format) and picks the member whose storage
UUID is the catalog entry's. The chart enables both sides with `nvr.read`, and
its NetworkPolicy admits web-ng pods only, to the read port only.

## Archive upload

The same authenticated listener copies one sealed local block to an
S3-compatible bucket and keeps the local copy. Core resolves the bucket
credential from the unified CNPG credential inventory and sends it inside the
request; the NVR holds it in memory for that request only. It is never written
to disk, logged, returned or kept in a long-lived process. No Kubernetes Secret,
Helm value or environment variable carries it.

Send `POST /v1/blocks/<block_id>/archive`, where `block_id` is a 64-character
block ID from an ingest receipt, with exactly one
`Content-Type: application/vnd.serviceradar.nvr-archive.v1+json` header and a
canonical JSON body of at most 8192 bytes:

```json
{"credential":{"access_key_id":"EXAMPLEARCHIVEKEY","secret_access_key":"example-secret"},"destination":{"bucket":"example-archive","host":"objects.example.com","object_prefix":"recordings/v1","region":"example-region-1"},"recovery_generation":"00000000-0000-4000-8000-000000000077","storage_id":"00000000-0000-4000-8000-000000000011","version":1}
```

| Field | Rule |
| --- | --- |
| `storage_id`, `recovery_generation` | This NVR's storage UUID and boot-pinned recovery generation |
| `destination.host` | Path-style provider DNS name containing a dot, reached over TLS with public roots |
| `destination.region` | Signing region, 1 through 40 of `[a-z0-9-]` |
| `destination.bucket` | DNS-style bucket name, 3 through 63 bytes |
| `destination.object_prefix` | 1 through 128 of `[a-z0-9/_-]`, no leading or trailing slash |
| `destination.port` | Optional, 1 through 65535; default 443 |
| `credential.access_key_id` | 1 through 256 printable ASCII bytes |
| `credential.secret_access_key` | 1 through 512 bytes of UTF-8 |

The client library accepts plaintext HTTP only to a numeric loopback address,
so the NVR uses plaintext exactly when `destination.host` is a `127.0.0.0/8`
literal, which serves the synthetic release-test peer. Core's archive
destinations are DNS names on port 443, so production requests never take that
path.

Order of checks: request shape and binding (400), recovery gate (503
`archive_unavailable`), one archive per NVR (503 `archive_busy`), verified sealed
block (404 `block_not_found`, 409 `block_not_sealed`), retained receipt, then
object size (422 `block_too_large` above 16 MiB). A retained receipt that
re-encodes byte-for-byte from this request and the verified block is returned
with 200 and no provider call. A receipt for another destination is refused with
409 `archive_receipt_conflict` and never replaced. `block_not_sealed` covers an
open journal and a block whose bytes fail their identity, digest or length
check. A local read or permission error on the block files or on
`archive-receipt.json`, or a receipt file that is not a private regular file, is
503 `archive_unavailable` and is logged once with `stage=block` or
`stage=receipt` and the error class, so the same request can be retried.

Objects are written under `<object_prefix>/<storage_id>/<block_id>/`: `init.mp4`
(the initialization bytes), `media.m4s` (the complete sealed media file) and
`descriptor.json` (the canonical descriptor bytes). Each PUT is a single attempt
with `If-None-Match: *`, SSE-S3 (`AES256`) and its SHA-256 checksum. HEAD binds
the object to its ETag, length and encryption, then ranged GETs of at most
4 MiB, bound to that ETag, must hash to the local SHA-256. A 412 on PUT means the
object already exists: it is verified the same way and never overwritten. An
unknown PUT outcome is not retried and no other transport is tried; any provider
failure answers 502 `{"error":"archive_failed","stage":"put|head|readback","object":"<name>"}`
and writes no receipt. A retry verifies whatever the provider retained. Each
failed archive logs one warning with the stage, object name and provider status
or error class only.

After all three objects verify, the client is closed and drained and
`archive-receipt.json` is written beside the block (temporary file, fsync,
rename, directory fsync) under the block's capacity allowance. The 200 response
carries the same canonical bytes:

```json
{"block_id":"<block_id>","destination":{...as requested...},"objects":[{"etag":"\"...\"","key":"recordings/v1/<storage_id>/<block_id>/init.mp4","length":1234,"name":"init.mp4","sha256":"<hex>"},...],"storage_id":"<storage_id>","verified_at_ms":1700000000000,"version":1}
```

Every block reserves 4096 bytes for its receipt alongside its publication
allowances; inventory accepts `archive-receipt.json` and an interrupted
`archive-receipt.json.tmp`, and charges both by size. The request, including the
provider work, client drain and receipt write, is bounded by 120 seconds. One
Longshore client per request uses concurrency 1 and a 16 MiB buffer (48 MiB
locked over TLS). A receipt names verified remote copies only: it is not a
catalog entry, playback grant or permission to delete the local block.

## Verification

`//elixir/serviceradar_nvr:release_test` owns the real HTTP/TLS and release-lifecycle
contract. Its network input cases use independently generated H264, verify
rotated footage by decoding and comparing frames after restart, preserve files
on replay, and exercise authentication, storage/generation binding, incomplete
input, bootstrap refusal and finite producer lifetime. These tests establish
neither deployed-camera behavior nor physical Longhorn node-loss durability.
The same target runs the packaged client against the packaged NVR and an
independent TLS peer to check wire bytes, receipt binding, server identity,
byte limits, no retries and bounded cleanup after producer or caller failure.
The same target reads a network-ingested block's descriptor over mutual TLS,
checks it against the block's files and the packaged client, and checks the
401, 404 and 409 answers and that the client refuses non-canonical bytes and
descriptors for another block.
The same target reads a block's init segment and every fragment through the read
listener and decodes them with an independent decoder, checks the read client's
typed refusals, the 400/401/404/409 answers, that read and ingest credentials
open only their own listener, and that the NVR refuses to start when the read
installation shares the ingest port, pin or token.
The same target checks status, lookup and ledger pages against a sealed and an
unsealed block and through the packaged client, refuses malformed requests, and
checks the block ledger: the cap refuses admission while reads and lookups keep
working, a restart rebuilds the same charge, a directory the ledger did not
record closes admission without changing any file, and a volume larger than one
rebuild page reports `rebuilding` before it is ready.
`//elixir/serviceradar_nvr:archive_release_test` runs the archive cases of the
same harness on the Longshore-qualified executor pool: the packaged client
archives a network-ingested block to a synthetic loopback object store, every
object is compared byte-for-byte, the receipt survives restart and inventory,
and refused, corrupted, existing-object, invalid, unsealed and concurrent
requests are checked.
