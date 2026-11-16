# Design: NVR continuous recording, retention and unified timeline playback

This design extends, and does not restate, the approved
[scalable recording plane](../add-scalable-camera-recording-plane/design.md)
(sections 5, 6, 9 and "Object storage playback and bounded buffering"), its
[local publication contract](../add-scalable-camera-recording-plane/local-publication.md),
and the [VMS storage and playback engine](../add-vms-storage-playback-engine/design.md).
It composes with the pending `add-nvr-operator-settings` change and uses that
change's names: the `/settings/recording` view, `RecordingArchiveSettings`,
`NVRArchiveReceipt`, `RecordingOperation`, `CameraRecordingPolicy` and the NVR
`GET /v1/status` and `POST /v1/blocks/lookup` endpoints.

Scope is the in-cluster placement that ships today: core-elx hosts the camera
relay and feeds `serviceradar-nvr` members over the private ingest listener.
Recorder pools, customer-host enrollment, offline grants and cross-recorder
handoff remain recording-plane work.

## 1. Constraints verified in source

All references are to `origin/staging` at the time of writing.

| Fact | Where |
| --- | --- |
| A volume holds at most 4,096 block directories | `elixir/serviceradar_nvr/lib/serviceradar_nvr/disk.ex:7` (`@max_blocks 4096`) |
| Inventory fails outright above the cap | `disk.ex:20` (`length(blocks) <= @max_blocks \|\| {:error, :nvr_inventory_limit}`) |
| Every inventory lists the root and `lstat`s every file of every block | `disk.ex:13-31`, `disk.ex:58-86` |
| Admission refuses when blocks + active reservations + 1 exceeds the cap | `capacity.ex:341-357` (`:nvr_inventory_limit` at 344-346) |
| `reserve`, `next_block`, `status` and every publication or receipt write run a full inventory | `capacity.ex:55-73`, `84-101`, `116-119`, `171-182`, `290-315` |
| A block is at most 16 MiB and 4 MiB per fragment; fragments per block are `SERVICERADAR_NVR_MAX_BLOCK_FRAGMENTS`, default 150, 8 to 256 (merged in #6660) | `capacity.ex:13` (`@block_bytes`), `config.ex:29` |
| Fragments are cut at the first keyframe at or after 2 s | `elixir/serviceradar_recording/lib/serviceradar_recording/packaging.ex:52-60` (`segment_min_duration_ns: 2_000_000_000`) |
| The writer rotates to a new block when the configured fragment count or 16 MiB is reached | `spool.ex:325-339` (`:block_full`), `writer.ex:73-92`, `session.ex:111-120` |
| Core caps one capture at 270 s, 8,100 frames, 12 MiB (defaults 6 s, 240, 8 MiB) | `elixir/serviceradar_core_elx/lib/serviceradar_core_elx/camera_recording/nvr_worker.ex:48-55` |
| Core accepts a success receipt only if it names exactly the one reserved block | `nvr_worker.ex:585` (`block_ids: [^expected_key]`); anything else becomes `{:unexpected_nvr_receipt, _}` at `nvr_worker.ex:606` and is finalized as uncertain |
| The wire contract allows up to 256 consecutive block IDs per request | `elixir/serviceradar_nvr_client/lib/serviceradar_nvr_client/wire.ex:52-63`, `ingest.ex:126-146`, `docs/nvr-ingest.md` "Finite stream contract" |
| One ingest request admits at most 64 MiB of body; session duration code default 30 s, ceiling 300 s; the chart sets 300 s and 150 fragments per block | `docs/nvr-ingest.md` lines 125-129; `config.ex:28`; `helm/serviceradar/values.yaml:3312`, `3316` |
| One NVR member runs 1 recording session by default, 16 at most | `config.ex:20` (`SERVICERADAR_NVR_MAX_SESSIONS`, 1, 16) |
| Default spool budget is 1 GiB, reserve 64 MiB | `config.ex:22-23` |
| One archive per member; whole block held in memory; single PUT per object, no retry | `application.ex:26` (`ArchiveTasks max_children: 1`), `archive.ex:36-42`, `archive.ex:234-251`, `archive.ex:296`, `archive.ex:337-348` |
| Archive objects: `init.mp4`, `media.m4s`, `descriptor.json` under `<prefix>/<storage_id>/<block_id>/`, readback in 4 MiB ranges | `archive.ex:42`, `archive.ex:242`, `archive.ex:426` |
| Archive receipt is at most 4,096 bytes on the volume; it records ETag but not object version | `publication.ex:33-35`, `archive.ex:428-447` |
| Local reads: 4 slots, 10 s each, shared by archive, inventory and verification | `application.ex:21`, `reads.ex:2-10` |
| Recorded blocks carry `utc_mapping: "unknown"`; receipt time is not capture time | `nvr_worker.ex:255-262`; `packaging.ex:7-8`; `docs/nvr-ingest.md` line 111-112 |
| The descriptor clock already admits an explicit mapping `{origin_media_ticks, origin_utc_usec, uncertainty_usec}` | `elixir/serviceradar_recording_metadata/lib/serviceradar_recording_metadata/descriptor.ex:108-125` |
| Only a live original recorder may freeze a block's descriptor | `elixir/serviceradar_core/lib/serviceradar/camera/recording_blocks.ex:32-52`; states `open_local \| sealed \| uploading` at `recording_block.ex:172-175` |
| Archive credential roles: writer PUT/HEAD/GET, reader HEAD/GET; no delete role | `elixir/serviceradar_core/lib/serviceradar/camera/archive_credential_resolver.ex:173-174` |
| The Longshore adapter exposes put, head and get only (no delete, no multipart) | `elixir/serviceradar_object_storage/lib/serviceradar_object_storage.ex:34-64` |
| A Longshore buffer is 8 KiB to 16 MiB; a client's registered (locked) buffers are bounded at 64 MiB, and over TLS it registers `3 * concurrency * max(buffer_size, 256 KiB)`, so the largest single-buffer PUT is 16 MiB; at most two live clients per VM, including draining ones | `elixir/serviceradar_object_storage/README.md` "Resource limits" |
| Multipart upload is not implemented | `openspec/changes/add-longshore-object-storage/tasks.md` task 2.2 |

### 1.1 What happens at the 4,096-block cap

Read from the code (not exercised against a full volume):

- Admission counts sealed and incomplete block directories alike (`disk.ex:11-12`).
  With 4,096 present, `Capacity.admission/1` returns `{:error, :nvr_inventory_limit}`
  for `reserve` (`capacity.ex:344-346`). `ServiceRadarNVR.Session.init/1`
  stops with that reason (`session.ex:25`, `40`), `start_recording` fails, and
  the ingest route answers 503 `ingest_unavailable` (`ingest.ex:55`, `77`).
  Every new recording on that member is refused.
- A session that is already recording and needs another block fails at
  `Capacity.next_block/1` with the same error (`session.ex:115`); the writer
  stops, the journal is kept and the request answers 422 `ingest_incomplete`
  (`ingest.ex:67-69`).
- Admission keeps the count at or below the cap, so `Disk.inventory/1` itself
  still succeeds: `status`, `list_blocks`, publication intents, archive uploads
  and archive receipt writes keep working (receipt and publication writes check
  bytes only, `capacity.ex:321-333`). Single-block reads do not inventory
  (`serviceradar_nvr.ex:92-136`).
- If the root ever holds more than 4,096 entries (stray directories, a restore
  or a future bug), `Disk.inventory/1` fails, so `measure/2` fails and with it
  `reserve`, `next_block`, `status`, `list_blocks`, `recover_block`, publication
  writes and archive receipt persistence (`capacity.ex:290-315`). An archive
  upload would then copy and verify all three objects and fail only at the
  receipt write. Single-block reads still work.
- Nothing in the NVR deletes a block, so a member that reaches the cap stays
  full until an operator intervenes.

### 1.2 The rotation hazard that #6660 removed

Before #6660 a block held at most 8 fragments while a capture could last 25 s.
With a source GOP of 2 s or less, fragments are about 2 s long, so 8 fragments
were reached after about 16 s, and a longer capture made the NVR rotate into a
second block within the same request (`session.ex:111-120`). The NVR then
returned two block IDs and the Core worker treated the result as uncertain
(`nvr_worker.ex:585`, `606`), even though both blocks sealed. Blocks rotated
that way may still sit on existing volumes; the reconciler handles them (R3,
PD1).

The current sizing removes the hazard. With 150 fragments per block and a 2 s
minimum fragment, a block can hold at least 300 s of media, which exceeds any
capture under the 270 s ceiling; at most about 136 fragments fit in 270 s. The
12 MiB capture byte ceiling stays below the 16 MiB block byte limit. A capture
therefore always fits in one block.

## 2. Decisions at a glance

| Topic | Decision |
| --- | --- |
| Segment length | Block = one ingest request = up to 270 s, 8,100 frames or 12 MiB of media, whichever comes first, cut at a keyframe (the block sizing merged in #6660) |
| Per-capture bound vs multi-block sessions | Raise the per-capture time and frame bounds, keep the 12 MiB byte bound, and keep one block per request; do not rely on multi-block responses |
| NVR block bounds | 16 MiB (unchanged), fragments per block configurable `SERVICERADAR_NVR_MAX_BLOCK_FRAGMENTS` default 150 (8 to 256), 2 s minimum fragment (unchanged) |
| Blocks above 16 MiB | Later item, blocked on multipart upload (Longshore task 2.2) |
| Volume block cap | Replace the per-admission scan with an incremental ledger; install bound default 131,072, ceiling 262,144 |
| Local tier | A bounded cache with a byte budget: install default 85% of the PVC minus a reserve of max(64 MiB, 1%), editable per member at runtime and delivered to the NVR (C9); NVR budget ceiling raised from 1 TiB to 1 PiB; evict reconciled local copies that are archive-verified or whose archive copy was deleted by object retention or the reaper, and are not a hold's pinned copy, oldest first at 90% down to 80%, or past a maximum local age (default 24 h, up to 10 years, or unlimited); the effective window is computed and shown |
| Local-only | A complete mode: everything works with no destination, and pages say so plainly |
| Local-only full policy | Explicit `overwrite_oldest` (UI preselects, operator confirms) or `stop_when_full` (code behaviour when nothing was selected); 7 d becomes a target with an alert |
| Object retention | Default 30 d, bounds 1 d to 3,650 d, or unlimited; expiry deletes only the archive copy and leaves any local copy as local only, evictable by the local rules; the settings UI warns, without refusing, when a limited retention is shorter than a limited maximum local age |
| Storage alerts | Through `TripwireHealth.record/4` (deduplicated, auto-clearing); surfaced by operator notices (#6359) when that lands |
| Holds | Keep at least one verified copy: pin the archive copy when verified, else the local copy (PD5) |
| Object capacity | Optional object budget with watermarks and a recorded policy, `reap_oldest` (deletes only the archive copies of the oldest unheld blocks; local copies stay as local only, evictable by the local rules) or `stop_archiving`; effective object retention computed and shown (C3a) |
| SaaS | One storage entitlement per deployment pushed at runtime on the private listener (no Helm value), bounding the object budget, policy, retention and cameras; shared retention formula with test vectors; usage report pulled by control; Cloud credentials into the CNPG inventory (F) |
| Delete vs lifecycle | ServiceRadar deletes expired objects itself with a separate delete-capable retention role; provider lifecycle only for incomplete uploads and probe residue |
| Catalog shape | Freeze the existing `RecordingBlock` under the original recorder fence, plus a separate `RecordingCatalogEntry` projection for copy location and retention |
| Time mapping | `time_basis = received`: wall-clock positions from Core's receipt of the first access unit, spacing from media timestamps; uncertainty reported as unmeasured. Camera-reported time (RTCP) is a later basis |
| Media compression | No zstd or other general-purpose compression of media objects |

## 3. Product decisions (2026-11-15)

The product owner delegated these decisions; each is recorded here with its
rationale and is no longer an open question.

**PD1. Rotated-block adoption: adopt only on proof of continuation.** A block the
NVR rolled into is adopted only when it provably continues a block Core
reserved (R3): the reserved predecessor is adopted, the candidate's key is
derived from the predecessor's identity with the next sequence, the journal
identity differs only in sequence and carries the same clock epoch, and no
reservation row exists for that capture identity. This is a narrow, stated
amendment to the recording plane's local publication contract, whose
acceptance table rejects "a new recorder freezing an unknown older block" and
leaves blocks without established authority unresolved until plane task 1.3.
The amendment covers only this continuation case; every other unknown block
stays rejected. When the proof fails, the block is unattributable: an alarm is
raised and an operator decides (R4 step 6). Rationale: the rotated block was
written by the same writer, in the same request, under the same claim and clock
epoch as a block Core did authorize; refusing it would strand real footage
that the product rule says must not be stranded, while the proof keeps
"trust whatever is on disk" out.

**PD2. Playback before local-copy registration: provisional, with archive
fallback.** Unregistered local copies play, labelled "provisional", and a
fragment falls back to the verified archive copy (D3). This relates to
[define-nvr-local-copy-registration](../define-nvr-local-copy-registration/design.md)
as follows: a catalog entry is not a local-copy registration and claims no
qualified protection; the "provisional" label is exactly the VMS requirement
"Provisional local playback"; and when registration exists for a copy's storage
lifetime and qualification is current, the label is removed for that copy.
That change's statement that the catalog must not advertise playable
availability before registration is read as "must not advertise qualified
availability"; this change never does. Rationale: the timeline must be usable
now, and the honest label carries the difference.

**PD3. Object retention: 30 days, enforced by ServiceRadar.** Default 30 days.
ServiceRadar deletes expired archive copies itself with a delete-only retention
credential role (DELETE, HEAD); with no retention credential selected, object
retention is shown as "not enforced" and nothing is deleted (C3).

**PD4. Local-only full policy: overwrite-oldest preselected and confirmed.** The
UI preselects `overwrite_oldest` and the operator confirms it; the confirmation
is recorded with the actor. With nothing recorded the behaviour is
`stop_when_full` (C2).

**PD5. Holds keep at least one verified copy, preferring the archive.** When a
verified archive copy exists, a hold pins the archive copy and the local copy
stays evictable by the local budget and age rules, so long investigations do
not consume the hot tier. In local-only mode, or before the archive copy is
verified, the hold pins the local copy; when the archive copy becomes verified
the pin moves to it. This replaces the earlier rule that a hold pinned every
copy (C4). Rationale: the hold's purpose is preservation, which one verified
copy satisfies; pinning the hot tier for weeks of investigation would shrink
everyone's local window.

**PD6. Local budget install default accepted.** 85% of the volume minus a
reserve of max(64 MiB, 1%) (C1).

**PD7. Object-tier capacity budget.** Purchased or fixed-size buckets must not
make the product break, so the object tier gets a byte budget symmetric with
the local tier, with an explicitly selected, recorded capacity policy (C3a). In
SaaS the budget and policy come from the deployment's storage entitlement
(stage F). The reaper (`reap_oldest`) deletes only archive copies, oldest unheld
blocks first, from high water down to low water. A block whose local copy still
exists keeps it; the catalog records the block as local only after archive
reaping, and from then on the local copy is governed exactly like local-only
footage: it stays until the local budget or the maximum local age requires
eviction, oldest first, and it is evictable, not pinned as unarchived. It is
never re-archived automatically, because that would refill the bucket and loop.
Selecting `reap_oldest` also authorizes that later local eviction, which
deletes the last copy; the settings page says so before the selection is
recorded. Time-based object retention behaves the same way. Rationale: an
operator with a lot of local disk keeps footage locally for as long as it fits,
whatever the bucket's size; the bucket bounds only the archive copies, and a
reaped archive copy no longer strands its local copy, because that copy stays
evictable.

## A. Continuous recording that fits the volume

### A1. Block sizing

Stage A uses the block sizing merged in #6660 (`feat/nvr-longer-blocks`) as
its baseline and does not change it:

| Bound | Before #6660 | Current (baseline for Stage A) |
| --- | --- | --- |
| NVR fragments per block | 8 | `SERVICERADAR_NVR_MAX_BLOCK_FRAGMENTS`, default 150, range 8 to 256 (`config.ex:29`) |
| NVR block bytes | 16 MiB | 16 MiB (`capacity.ex:13`) |
| Minimum fragment duration | 2 s | 2 s |
| Core capture duration ceiling | 25 s | 270 s (`nvr_worker.ex:55`) |
| Core capture frames ceiling | 1,800 | 8,100 (`nvr_worker.ex:53`) |
| Core capture bytes ceiling | 12 MiB | 12 MiB (`nvr_worker.ex:54`) |
| Chart NVR session limit (`SERVICERADAR_NVR_MAX_DURATION_MS`) | 30 s | 300 s, the service ceiling (`values.yaml:3312`) |

Why the byte limit stays at 16 MiB: the archive path reads a whole block into
memory and sends each object in one PUT with a buffer of the object size
(`archive.ex:87`, `archive.ex:234-251`). A Longshore buffer is at most 16 MiB,
and a client's registered (locked) buffers are bounded at 64 MiB; over TLS it
registers the lent buffer plus two record buffers of the same size per
connection, so one 16 MiB PUT already uses 48 MiB
(`elixir/serviceradar_object_storage/README.md`, "Resource limits"). A larger
configuration returns `:bad_config`. The largest single-buffer PUT is therefore
16 MiB, which is why the shipped archive path and the NVR block limit are both
16 MiB. Blocks above 16 MiB need multipart upload, which is not implemented
(Longshore task 2.2); they are the later item A8.

Blocks per day per camera is `86,400 / block seconds`. The volume cap, the
object request count and the Core row count all scale with it. A block closes
at the earliest of 270 s, 8,100 frames or 12 MiB of media. 12 MiB in 270 s is
about 373 kbit/s, so a stream above roughly 370 kbit/s closes on bytes first and
makes more blocks; at 30 frames per second the frame bound equals 270 s, and at
60 frames per second it closes at 135 s (640 blocks per day). Illustrative
figures at the hard bounds (assumed bitrates, not measurements):

| Recorded bitrate | Block closes on | Block length | Blocks per camera per day | Days of one camera in 4,096 blocks | Bytes per day |
| --- | --- | --- | --- | --- | --- |
| up to about 370 kbit/s | time | 270 s | 320 | 12.8 | up to 4.0 GB |
| 1 Mbit/s | bytes | about 101 s | about 858 | 4.8 | 10.8 GB |
| 2 Mbit/s | bytes | about 50 s | about 1,717 | 2.4 | 21.6 GB |
| 4 Mbit/s | bytes | about 25 s | about 3,433 | 1.19 | 43.2 GB |
| 8 Mbit/s | bytes | about 12.6 s | about 6,866 | 0.6 | 86.4 GB |

For comparison, the 25 s ceiling before #6660 gave 3,456 blocks per day and its
practical 8-fragment cap (about 16 s) gave 5,400. The keyframe-aligned soft
cuts in A4 (260 s and 10 MiB) close blocks a little earlier, so real counts are
up to about 4% higher for time-closed blocks and up to 20% higher for
byte-closed blocks than this table.

What this sizing achieves and what it does not:

- Low-bitrate profiles (substreams under roughly 370 kbit/s) drop from 3,456 to
  320 blocks per camera per day, a factor of about 11.
- Profiles at or above about 4 Mbit/s get no reduction: 12 MiB closes the block
  in about 25 s, as before #6660. For them the volume cap is handled by the ledger
  (A5) and, later, by blocks above 16 MiB (A8).
- Seek granularity does not depend on block length: playback reads 2 s
  fragments by byte range (D4).
- A longer block delays its archive copy by up to its length. That window is
  covered by the replicated volume, which is the plane's durability boundary
  for unarchived media (plane design section 5).

### A2. One block per ingest request

Decision: raise the per-capture time and frame bounds, keep the byte bound, and
keep exactly one block per request. Do not use multi-block requests for
continuous recording.

- Each block then has its own definite outcome within seconds of sealing. A lost
  response leaves one block uncertain, not a whole multi-block session.
- Core reserves block sequences one at a time under the recorder claim
  (`RecorderOwnership.reserve_block`, `recorder_ownership.ex:101-131`). A request
  that rotated inside the NVR would create block identities Core never
  reserved. One block per request keeps every block reserved before it exists.
- The existing worker check (`block_ids: [^expected_key]`) stays correct.
- The cost is one handover per block (A4), at most every 270 s and, for
  byte-closed blocks, as often as the bitrate dictates.

The coordinator's hard bounds sit strictly inside one NVR block: at most 12 MiB
of media and about 136 fragments in 270 s, against 16 MiB and 150 fragments in
the NVR (section 1.2). The NVR's own rotation remains a safety net that Core
reports as an error, never as success.

The continuous path uses the same ceilings as bounded captures. The Core
capture timeout ceiling stays at 300 s and the NVR session ceiling stays at
300 s, which leaves 30 s for sealing after a 270 s capture. The 64 MiB request
body limit is unchanged and far above 12 MiB. NVR sessions per member keep
their ceiling of 16; the chart sizes the default to the member's assigned
cameras.

The fragment count, session duration and session count are workload resource
bounds, which the settings change already classifies as install topology (its
D3), so an environment value is correct for them.

### A3. Continuous coordinator

`CameraRecordingPolicy` (named by the settings change, D13) gains the fields in
E1. An enabled `continuous` policy starts one `ContinuousRecorder` in core-elx
under `ServiceRadarCoreElx.CameraRecording.Supervisor`, on the node that hosts
the relay pipeline (`ServiceRadar.Camera.RelayHosts`), as `NVRCapture` does
today. It:

1. Opens or reuses the shared relay through `RelaySessionManager.request_open/3`
   and holds a recorder consumer lease on `IngestOwnership`, so the relay stays
   open with no viewers (plane task 2.4, scoped to this placement).
2. Acquires one `RecorderOwnership` claim bound to the policy's NVR member
   storage and keeps renewing it for the whole run. Clock epoch is
   `relay_session_id:recorder_epoch`, constant for the run.
3. Attaches one bounded inbox to the relay pipeline for the run. The inbox
   stamps each access unit with the core-elx node's UTC time at admission
   (used by the time basis, section T).
4. Loops: reserve the next block sequence, open one ingest request, stream
   access units until a cut point (A4), end the stream, await `sealed_local`,
   then register the block (B2) and, when the block archives (A6), enqueue
   its archive.
5. Ends the run on policy disable, relay session end, recorder claim loss,
   recovery gate closure or an unresolved block (below). A new run starts with
   a new claim and clock epoch; the boundary is a recorded gap.

Placement is explicit. The policy names one NVR member. Changing it is an
assignment transition: stop, seal, release, then start on the new member.
Existing blocks keep their storage identity (settings change, "Policy edit").

Uncertain outcomes reuse the shipped rules (no automatic resend, no failover)
with one addition that continuous recording needs. Because the coordinator
still holds the original claim, it queries `POST /v1/blocks/lookup` for the
block key once the NVR's request deadline has passed:

| Lookup result | Action |
| --- | --- |
| `sealed` | Fetch the descriptor, freeze and register under the live claim, continue |
| `absent` | Record a gap for the block's interval, continue with the next sequence |
| `incomplete` or `unresolved` | End the run and hand the block to the reconciler (section R), which recovers it after writer retirement or records a gap |
| member unreachable | Retry lookup within a bounded window, then end the run; the reconciler resolves the block when the member returns |

The NVR registers sessions by source and profile (`session.ex:10-16`), so a
second request for the same camera cannot start while an earlier one is still
running. That serializes handover without a Core lock.

### A4. Keyframe-aligned handover

At the soft target (260 s, 7,800 frames or 10 MiB) the coordinator waits for the next IDR
access unit (detected from AnnexB NAL type 5, or the relay's keyframe flag when
present), ends request N before it, and opens request N+1 with that IDR first.
The packager admits it immediately (`wait_for_keyframe?: true`). Access units
that arrive while N seals and N+1 opens wait in the run's bounded inbox (the
shipped worker uses 128 samples and 16 MiB, about 4 s at 30 frames per second).

If no IDR arrives before the hard bound (270 s, 8,100 frames or 12 MiB), the
coordinator cuts immediately and N+1 starts at the next IDR. If the inbox
overflows during a handover, the dropped units are a gap. The soft-to-hard
margins (10 s, 300 frames, 2 MiB) are sized for the packager's default 5 s
maximum keyframe interval; a 2 MiB margin covers one 5 s GOP up to about
3.3 Mbit/s, so higher-bitrate streams with long GOPs cut at the hard bound more
often and record a short `keyframe_wait` gap.

Because the coordinator sees every access unit, its gap accounting is exact
within a run:

- **Contiguous**: N+1's first relay sequence is N's last plus one. No gap.
- **Measured gap**: sequences were skipped. The gap's duration is the PTS
  difference between N's last unit (plus its duration) and N+1's first, in
  the run's 90 kHz timebase. Its reason is recorded (A7).
- **Epoch boundary**: a new run. The gap is measured on the time basis
  (section T) and carries that basis's uncertainty.

Whether consecutive blocks also have continuous `tfdt` timestamps in the
packaged fMP4 depends on whether each new packager instance preserves the
input PTS origin. That is to be verified; the playlist handles both cases (D2).

### A5. Inventory ledger and the volume block cap

The cap exists because inventory is a full directory scan on every admission,
publication write and status call (section 1). Raising the cap without changing
that would make each admission proportionally slower, inside the
`ServiceRadarNVR.Capacity` GenServer that serializes all of them.

Decision: `Capacity` keeps an incremental ledger of blocks (directory, charged
bytes, missing publication allowances, receipt and tombstone state). It is
rebuilt once at boot by a paged, bounded scan, during which admission refuses
with `:nvr_inventory_rebuilding`. It is then updated by every create, append,
seal, receipt write and reclaim that passes through `Capacity`, and verified by
a periodic bounded audit (a fixed number of directories per tick, rotating).
An audit mismatch closes admission and reports `:nvr_inventory_mismatch`; it
never repairs or deletes.

The cap becomes an install bound, `SERVICERADAR_NVR_MAX_BLOCKS`, default
131,072, ceiling 262,144. Sizing against the A1 figures, with each camera
keeping 24 h hot plus a 24 h archive-outage margin (48 h of blocks):

| Recorded bitrate | Blocks per camera for 48 h | Cameras per volume at 4,096 | Cameras per volume at 131,072 |
| --- | --- | --- | --- |
| up to about 370 kbit/s | 640 | 6.4 | 204 (the 16-session limit binds first) |
| 1 Mbit/s | about 1,716 | 2.4 | 76 (sessions bind first) |
| 2 Mbit/s | about 3,434 | 1.2 | 38 (sessions bind first) |
| 4 Mbit/s | about 6,866 | 0.6 | 19 (sessions bind first) |
| 8 Mbit/s | about 13,732 | 0.3 | 9.5 |

Why 131,072: it is above what a 100 GiB to 1 TiB volume needs. On a 1 TiB budget
byte-closed 12 MiB blocks number about 87,400, so the count binds before bytes
only for blocks smaller than about 8.4 MB (streams under roughly 250 kbit/s on
270 s blocks). At roughly 200 bytes per ledger entry the ledger is about 26 MB
at the default and 52 MB at the 262,144 ceiling; the paged boot rebuild of that
many directories is the cost to measure. Operators with larger volumes raise
the install value toward the ceiling.

**What constrains keeping footage indefinitely on very large volumes.** Bytes do
not (C1: the budget ceiling becomes 1 PiB). Block count does:

- Blocks are at most 16 MiB until multipart exists (A1, A8), so retained blocks
  grow with retained bytes: 10 TiB of 12 MiB blocks is about 874,000 blocks; of
  4 MB low-bitrate blocks, about 2.7 million.
- The volume root is one flat directory. Inventory lists it in one call
  (`File.ls(storage.root)`, `disk.ex:15`), which builds the whole name list in
  memory, and today does so on every admission (section 1).
- Each block also costs one catalog row in CNPG.

So a flat volume is capped at 262,144 blocks: about 3 TiB of byte-closed
blocks, or about 1 TiB of 4 MB blocks. Beyond that, two later items apply, and
the settings page states the cap as the binding bound ("block cap") when it
binds before the budget:

- **A5b (later): sharded layout and aggregate ledger.** Newly installed volumes
  record a two-level layout (`<root>/<first two hex>/<block_id>`) in their
  bootstrap evidence, existing flat volumes keep theirs. The ledger keeps
  per-shard totals plus per-block entries only for blocks with missing
  publication allowances, so memory no longer grows with retained blocks, and
  boot rebuild streams one shard at a time. The block cap default then derives
  from the budget (budget / 4 MiB, at least 4,096, at most 16,777,216).
- **A8 (later): blocks above 16 MiB.** Multipart lets blocks close on time at
  any bitrate, cutting block counts by 12 to 24 times for higher-bitrate
  streams.

At the cap, behavior stays as in 1.1: admission refuses, the coordinator
records a gap with reason `nvr_inventory_limit`, and nothing is deleted to make
room (C5).

### A6. Automatic archive after seal

A block archives only when both hold: `RecordingArchiveSettings.archive_enabled`
is true and the block's policy stores `local_and_archive`. Then registering the
block (B2), from the live path or the reconciler, creates the catalog entry
with `archive_state = pending` and enqueues one Oban job (`ArchiveBlockJob`,
unique per catalog entry, queue `nvr_archive`). Otherwise the entry is created
with `archive_state = not_required` and nothing is enqueued. The job:

1. Re-reads the catalog entry; proceeds only if the archive state is `pending`
   or `failed_retryable` and the block still archives. If archiving has since
   been disabled or the policy changed to `local_only`, the entry moves to
   `not_required` (local-only footage, C2) and the job ends; blocks are not
   archived retroactively when archiving is enabled again.
2. Calls the shipped `NVRArchive.archive_block/5` with the active
   `ArchiveBinding` and the writer credential from `RecordingArchiveSettings`.
   The NVR still holds the credential only for that request.
3. On 200, records the `NVRArchiveReceipt` (settings change D9) and moves the
   entry to `verified` in one transaction.
4. On `archive_busy` (503), snoozes without consuming an attempt. On 502,
   other 503s and unknown outcomes, retries with jittered exponential backoff
   (30 s doubling to 30 min) indefinitely while the block exists. Retrying is
   safe by the archive contract: existing objects are verified, never
   overwritten, and an identical retained receipt is returned without provider
   calls. On 409 `archive_receipt_conflict` or 422, marks the entry
   `failed_terminal` with the error class and stops; these need an operator.
   A `failed_terminal` entry raises an operator-visible alarm immediately and
   stays on the health tab until an operator resolves it (R5); it is never a
   silent end state.

Every sealed block that archives (above) is archived. Dual write here means
"kept locally and copied after sealing", not a synchronous write to two places (settings change D13).

The NVR keeps one archive slot per member (`application.ex:26`). One slot holds
a block of up to 16 MiB in memory and 48 MiB of locked Longshore buffers. The
client library allows at most two live clients per VM, including draining
ones, so a second slot is the most the library permits and is a later tuning
item, not part of Stage A. Throughput must exceed capture: each block costs
about twice its bytes of provider traffic (upload plus full readback), and each
request opens its own client session. Whether one serial slot keeps up with a
member's assigned cameras (for example 16 cameras at 4 Mbit/s is 64 Mbit/s of
capture, needing well over 128 Mbit/s of effective archive throughput) must be
measured; the backlog reporting below shows a non-draining backlog when it does
not.

Backlog reporting is the settings change's "Archive backlog and health
reporting" requirement: pending count, oldest pending age, archive goodput
against capture rate, and a non-draining condition, published as JetStream
telemetry and read by the health tab. This change supplies the numbers from
the catalog and the archive jobs.

Archive pauses while Core is unavailable, because Core supplies the credential
per request. Local recording continues; the backlog grows on the replicated
volume and is bounded by admission (C5). Edge archive during Core outage
requires the plane's finite offline grants (task 1.3) and is out of scope.

### A7. Gap records

Gaps are first-class rows (`RecordingGap`, B3), written by the coordinator, not
inferred by the UI. Reasons:

| Reason | Meaning |
| --- | --- |
| `handover_overflow` | Inbox overflowed between two blocks |
| `keyframe_wait` | Hard bound reached without an IDR; units until the next IDR were not recorded |
| `source_unavailable` | Relay or camera stream down |
| `epoch_change` | Relay session or recorder claim changed; new run |
| `nvr_refused` | Admission refused, with class (`nvr_inventory_limit`, `nvr_spool_budget_exhausted`, `nvr_storage_pressure`, `nvr_recovery_closed`) |
| `block_absent` | Uncertain block resolved as absent |
| `run_stopped` | Run stopped for an unresolved block, claim loss or gate closure |
| `archive_capacity_exhausted` | Local tier full of unarchived footage because archiving is paused for object capacity (C3a) |

"Recording off" (policy disabled or outside its schedule) is not a gap; the
timeline shows it as not scheduled.

### A8. Later: blocks larger than 16 MiB

Blocked on multipart upload in the Longshore adapter (Longshore task 2.2) and
its qualification against the selected provider (recording-plane task 3.4).
With multipart, a block's media object can be sent as several parts of at most
16 MiB each, so the block byte limit is no longer tied to one buffer and blocks
can close on time (for example 300 s) at any bitrate.

The benefit is mostly request count and object count for higher-bitrate
streams. Reasoning, with 300 s blocks and 16 MiB parts:

| Recorded bitrate | Today, 12 MiB blocks: PUT + HEAD per camera per day | With multipart, 300 s blocks: write-side requests per camera per day | Blocks per camera per day |
| --- | --- | --- | --- |
| 4 Mbit/s | about 20,600 (3,433 blocks x 6) | about 4,600 (288 x 16) | 3,433 to 288 |
| 8 Mbit/s | about 41,200 (6,866 x 6) | about 7,200 (288 x 25) | 6,866 to 288 |

The multipart counts assume per block: PUT and HEAD for `init.mp4` and
`descriptor.json`, then create, one request per 16 MiB part (about 9 parts at
4 Mbit/s, 18 at 8 Mbit/s), complete and one HEAD for `media.m4s`. That is about
4.5 to 5.7 times fewer write-side requests, and 12 to 24 times fewer blocks,
catalog rows and volume ledger entries. Readback GETs are unchanged because
they follow bytes. Multipart also brings its own failure modes (incomplete
uploads, ambiguous completion), which the plane and VMS designs already require
to be reconciled; a provider lifecycle rule for incomplete uploads (C3) applies
then.

## T. Time basis for a wall-clock timeline

Existing design already says: capture metadata includes PTS, clock epoch, UTC
mapping source and uncertainty; edge receive time alone does not establish
capture time because upstream buffering is unknown; prefer validated RTCP
sender mapping when present
([VMS design section 2](../add-vms-storage-playback-engine/design.md#2-shared-ingest-and-supported-media)).
The packager keeps an explicit unknown mapping and never substitutes server
time ([choices.md, "Preserve unknown clock mappings"](../add-vms-storage-playback-engine/choices.md)).
The RTCP experiment showed `mapped=true` is not a capture-time guarantee: a
contradictory sender report replaces the mapping with no plausibility check
([clock-capabilities.md](../add-vms-storage-playback-engine/clock-capabilities.md)).
Calendar filters were deliberately deferred until trustworthy camera-clock
mapping exists (choices.md, "Discover by publication time before adding
capture-time search").

A timeline needs a wall-clock position anyway. This change adds one, labelled
for what it is, without touching the block's immutable clock identity:

- **Basis `received` (Stage B).** The catalog stores, per block, the core-elx
  node's UTC time at which the inbox admitted the block's first access unit and
  that unit's PTS. Within a run, positions are `anchor_utc + (pts - anchor_pts) /
  90,000`, where the anchor is the run's first unit. Spacing between blocks in
  a run is therefore exact in media time and agrees with gap accounting.
- **Drift check.** For each block, the coordinator compares its own observed
  receive time with the anchored estimate. If they differ by more than 2 s (a
  camera clock that runs fast or slow, or a node clock step), the run
  re-anchors at that block. The timeline marks the boundary "time re-anchored",
  which is not a media gap.
- **Uncertainty.** Capture happened before receipt by an unmeasured delay
  (encoder, network, agent, gateway, relay queues) and the node clock has its
  own error. The catalog stores `time_uncertainty_us = NULL` for this basis,
  meaning unmeasured, not zero. The UI labels these times "received", and the
  API never calls them capture times.
- **Basis `camera_reported` (later, D-later).** When the agent forwards a
  validated RTCP sender-report mapping and the product contract for report
  freshness, plausibility and uncertainty growth exists, blocks reserved after
  a validated mapping carry it in their clock identity, which the descriptor
  already supports (`descriptor.ex:108-125`). Blocks reserved earlier stay
  `received`. A basis is never upgraded after the fact.

Timeline queries and cross-camera alignment use the stored basis and say which
one they used. Investigators see "aligned by receipt time" when cameras are
compared.

## B. Core catalog of NVR blocks

### B1. Shape

Decision: freeze the existing `RecordingBlock` and add a separate projection.

- **Freeze `RecordingBlock`.** The settings change notes NVR captures leave the
  row at `open_local` with no descriptor. The original recorder fence is the
  only place where a descriptor can be bound to a reserved identity
  (`recording_blocks.ex:32-52`): a projection that copied an NVR-supplied
  descriptor without it would catalog bytes with no historical authority. The
  frozen descriptor (identity, clock, codec, fragment map with offsets, lengths,
  timing and SHA-256) is the immutable evidence playback reads.
- **Separate `RecordingCatalogEntry`.** Copy location, archive progress,
  retention and time basis are mutable current state with different write rates
  and lifecycles. Putting them on `RecordingBlock` would overload a row whose
  state constraints serve the older `ArchiveUploads` publication path. The
  timeline also needs a narrow, time-indexed table; the descriptor JSON (up to
  150 fragment entries) is too wide for range scans. This mirrors the local
  publication contract's separation of publication, reachability and
  preservation.

Freezing makes the row `sealed`, which the older `ArchiveUploads` path can
claim by block ID. `RecordingBlocks.acquire_upload/4` refuses blocks whose
`storage_id` belongs to an NVR `LocalStorageBinding`, so the two archive paths
cannot both act on one block.

### B2. Registration

After `sealed_local`, the coordinator (and the shipped `NVRWorker`, so bounded
captures are cataloged too) fetches the canonical descriptor from the NVR
(`GET /v1/blocks/<id>/descriptor`, new, in the read pool) and calls a new
`RecordingBlocks.freeze_and_catalog/6` that, in one transaction under
`RecorderOwnership.with_current`, freezes the descriptor and inserts the catalog
entry. An exact retry returns the existing entry; a different descriptor is
`recording_descriptor_conflict`. No network I/O happens inside the transaction.

Blocks whose original claim is gone (uncertain outcomes, a crashed
coordinator, blocks recorded before this change, or a block the NVR rotated
into) cannot be frozen by this path. The reconciler (section R) adopts them
under the authority stated there, or records them as gaps or unattributable
blocks. They are never left as unexplained local bytes.

### B3. Resources

`ServiceRadar.Camera.RecordingCatalogEntry`, table
`platform.camera_recording_catalog`:

| Field | Notes |
| --- | --- |
| `id` | UUID |
| `recording_block_id` | FK restrict, unique; the frozen block |
| `camera_source_id`, `stream_profile_id`, `policy_id` | Denormalized for indexes |
| `storage_id`, `block_key` | Unique pair; the NVR copy identity |
| `clock_epoch`, `run_id` | Run grouping for continuity |
| `media_start_ns`, `media_end_ns` | From the descriptor's first and last fragment |
| `first_unit_pts`, `first_unit_received_at` | Raw observation for the time basis |
| `timeline_start_us`, `timeline_end_us` | Derived wall-clock range (UTC microseconds) |
| `time_basis`, `time_uncertainty_us`, `anchor_id` | `received` now; NULL uncertainty means unmeasured |
| `contiguous_with_previous` | True when sequence-contiguous with the previous block of the run |
| `fragment_count`, `media_bytes`, `init_sha256`, `descriptor_sha256` | From the frozen descriptor |
| `local_state`, `local_state_at` | `present`, `reclaiming`, `reclaimed`, `missing` |
| `archive_state`, `archive_state_at` | `not_required`, `pending`, `failed_retryable`, `failed_terminal`, `verified`, `deleting`, `deleted`, `missing` |
| `archive_deleted_reason` | Set once when `archive_state` becomes `deleted`: `object_retention`, `object_capacity` or `operator`; with `local_state = present` the entry is local only after archive expiry or reaping (C3, C3a) |
| `archive_binding_id`, `nvr_archive_receipt_id` | FK restrict, set at `verified` |
| `archive_attempts`, `archive_last_error_class` | Bounded class, no provider text |
| `sealed_at`, `archived_at` | Database time |

Indexes: `(camera_source_id, stream_profile_id, timeline_start_us)`; partial on
`archive_state IN ('pending', 'failed_retryable')`; partial on
`(storage_id, sealed_at) WHERE local_state = 'present'`; partial on
`(archived_at) WHERE archive_state = 'verified'`.

`ServiceRadar.Camera.RecordingGap`, table `platform.camera_recording_gaps`:
camera, profile, policy, run, `start_us`, `end_us` (set once when the gap
closes), `media_gap_ns` (exact, within a run), `time_basis`, `reason`, bounded
`detail_class`. Append-only except closing `end_us`.

Row volume: at 320 blocks per camera per day (time-closed) up to about 3,433
(4 Mbit/s) or 6,866 (8 Mbit/s), 100 cameras for a year is roughly 12 million to
125 million catalog rows, and up to about 250 million at 8 Mbit/s. Blocks above
16 MiB (A8) would bring this back to about 10.5 million. Timeline coverage queries aggregate
into bounded buckets (D4) and never load a day's rows into memory. Whether the
catalog becomes a Timescale hypertable is left to benchmarks, as the VMS design
already says (section 3); the first migration is a plain table with the indexes
above.

## R. Reconciliation: no stranded footage

Product rule (recorded 2026-11-15): footage captured at the edge must never be
left stranded on disk. "Kept on the volume and flagged" is not an acceptable end
state. Everything recorded ends up cataloged (and archived when the block
archives, A6), or is explicitly accounted for as a gap.

### R1. How footage is stranded today

Verified in source:

1. **Uncertain captures.** After streaming starts, any transport, timeout or
   receipt mismatch is finalized as uncertain (`nvr_worker.ex:598-615`) and
   surfaced as `{:error, {:nvr_ingest_uncertain, _}}` (`nvr_capture.ex:13`,
   `nvr_capture.ex:257-269`). The worker cancels its lease timer and, because
   `uncertain?` is set, never releases its claim (`nvr_worker.ex:247-248`). The
   claim's lease then expires. Freezing requires a live claim and an active
   relay (`recording_blocks.ex:32-52`, `recorder_ownership.ex:151-165`,
   `recorder_ownership.ex:215-222`, `recorder_ownership.ex:262-284`), so the
   reserved `RecordingBlock` stays `open_local` permanently. Any block the NVR
   sealed for that request stays on the volume with no catalog row.
2. **Rotated blocks.** A capture recorded before #6660 that rotated into a
   second block (section 1.2) was also finalized as uncertain, and the second block has no Core reservation
   at all. Such blocks may remain on existing volumes.
3. **Unsealed journals.** Incomplete blocks are "preserved for recovery"
   (`session.ex:103-107`, `docs/nvr-ingest.md` "Outcomes and preservation"), but
   nothing calls `ServiceRadarNVR.recover_block/2` (`serviceradar_nvr.ex:222`).
   It also refuses while any recording or publication is active on the member
   (`capacity.ex:128-136`), so on a member that records continuously it could
   never run.
4. **Unarchived sealed blocks.** `NVRArchive.archive_block/5` has no caller in
   `lib/` (it is run by hand); a block whose archive failed or was never
   requested stays local-only indefinitely.

These are observed on a test deployment as well as in the code: captures that
opened a new relay ended uncertain in a noticeable fraction of runs before a fix
now in review, and every capture that rotated did.

### R2. Invariant

For every block directory on an NVR volume, within a bounded time after its
writer retires, exactly one of these holds:

| End state | Meaning |
| --- | --- |
| Cataloged | A catalog entry exists (B3); if the block archives (A6: archiving enabled and policy `local_and_archive`), the archive copy is verified or being retried with backlog reporting and alarms (R5); otherwise `archive_state = not_required` |
| Gap | The block could not be recovered; a `RecordingGap` with reason `unrecoverable_journal` covers its interval and the residue is disposed through an audited disposition (R4) |
| Tombstoned | Deleted by retention through an audited disposition (C6) |
| Unattributable | No Core authority covers the block; an alarm is raised and an operator decision is required (R3, last row) |

"Unattributable" is the only state that keeps bytes without Core accounting, and
it is an alarm, not an end state. It exists because adopting bytes that no Core
reservation covers would trust whatever is on disk.

### R3. Adoption authority

The NVR volume is the source of truth for what exists locally; Core is the
source of truth for what was authorized. The reconciler adopts a block only when
both agree.

The authority is Core's own reservation record. `RecorderOwnership.reserve_block`
creates the `RecordingBlock` row under the live recorder fence before the NVR
creates any file (`recorder_ownership.ex:101-131`; "A block sequence is reserved
durably before filesystem creation" in the VMS choices). That row fixes the
identity (camera source, profile, recorder epoch, block sequence and clock),
the storage UUID, the ingest owner and epoch, the claim, the relay session and
the media ingest ID. The block key on disk is derived from that identity
(`descriptor.ex:73-75`), so Core computes the keys it expects; it never takes
an identity from the disk.

A historical freeze (`RecordingBlocks.freeze_historical/3`, system actor, called
only by the reconciler) replaces exactly one check of the live freeze, "the
claim is still live", with "the writer is retired", and keeps every other check:

| Check | Evidence |
| --- | --- |
| The block is on the reserved storage lifetime | NVR member's storage UUID equals the row's `storage_id` |
| Same identity | Block directory equals the row's `block_key`, and the verified journal identity, including the clock, equals `RecordingBlock.identity/1` of the row |
| Fence history | The row is `open_local` (or already frozen with the identical descriptor, an exact retry); no disposition tombstone exists for the key |
| Writer retired | The block is sealed (a sealed journal is immutable), or, for an incomplete journal, the row's claim is no longer live by database time, the Core worker for it has exited, and the NVR reports no active session for that source and profile |
| Recovery state | The deployment recovery gate is ready for the current generation, and the storage lifetime is not awaiting current-history reconciliation after a restore |

Live and historical freeze both take the same row lock (`recording_blocks.ex:226`
`lock/2`), so a late live freeze and a reconciler adoption serialize: the second
one sees an identical descriptor (exact retry) or a conflict.

Blocks the NVR rotated into have no row. Their authority is derived from the
reserved predecessor and nothing else:

- the predecessor row (sequence `n`) exists for the same camera, profile and
  recorder epoch, on the same storage UUID, and has been adopted or frozen;
- the candidate key is `Descriptor.block_key/1` of the predecessor identity with
  sequence `n + k`, for `k` from 1 up to the ingest limit of 255 further blocks
  (`ingest.ex:126-146`), checked in order and stopping at the first absent key;
- the candidate's verified journal identity equals the predecessor's except for
  the sequence, including the same clock epoch, which names the original relay
  session and recorder epoch (`nvr_worker.ex:255`);
- no `RecordingBlock` row exists for that capture identity (the `capture`
  identity in `recording_block.ex` is unique, and every allocation creates a row
  before disk, so absence proves the sequence was never allocated).

The reconciler then creates the missing row in one transaction with fields
copied from the predecessor, advances the claim's `next_block_sequence` past it
if that claim is still the same epoch, and freezes it historically. If any check
fails the block is unattributable.

Never: adopt by matching a hash alone, take identity from a journal, adopt a
block on another storage UUID, adopt under a later recorder's claim, or adopt
while history is unresolved after a restore.

### R4. Reconciler

`NVRReconcileJob` (core-elx, Oban, one job per NVR member, every 5 minutes and
after each uncertain capture) pages the member's inventory with the settings
change's `GET /v1/blocks?after=&limit=` endpoint, extended to report each
block's state (`sealed`, `incomplete`, `tombstoned`) and, for sealed blocks, the
descriptor SHA-256. For each block:

1. **Cataloged**: check the archive state; nothing else.
2. **Reserved row, sealed block**: fetch the descriptor, historical freeze,
   create the catalog entry, and enqueue archive only when the block archives
   (A6: archiving enabled and policy `local_and_archive`); otherwise the entry
   has `archive_state = not_required` and nothing is enqueued.
3. **Reserved row, incomplete journal**: once the writer is retired, call
   `recover_block/2` with the row's identity. The existing explicit recovery
   repairs the journal to its last committed fragment and seals it. Then treat
   it as a sealed block. The tail after the last committed fragment is a gap
   with reason `incomplete_tail` and its exact media duration when known.
4. **Rotated block**: apply the derived authority in R3, then as 2 or 3.
5. **Unrecoverable**: if recovery fails (`empty_block`, identity mismatch,
   corrupt or missing committed data), record a `RecordingGap` with reason
   `unrecoverable_journal`, the verification class and the interval known from
   the reservation (the run's timeline when available, otherwise the receipt
   time of the capture). After the gap commits and a 7-day grace (so an
   operator can place a hold and inspect), the residue is disposed through an
   audited disposition with reason `unrecoverable` (C6, C7). A hold extends
   this indefinitely.
6. **Unattributable**: no Core authority. Raise an alarm, list it with the
   evidence on the health tab, never adopt or delete automatically. The
   operator's options are an audited delete or an export for inspection.

Core reservations with no block on the volume (a reserved row whose key is
absent and whose writer is retired) become gaps with reason `block_absent`, and
the row is marked resolved so it is not re-examined.

The NVR changes this needs:

- `recover_block/2` refuses only when an active session or publication touches
  that block or its source and profile, instead of whenever any recording is
  active on the member (`capacity.ex:133-136`).
- The inventory page reports block state and the descriptor digest.
- Recovery and the reconciler's reads use the existing read pool, bounded per
  page.

Bounds: at most 100 blocks per page, at most one recovery at a time per member,
and per-pass time and count limits; a pass resumes from its cursor.

### R5. Archive catch-up and alarms

Archive retry is the A6 job: jittered exponential backoff (30 s doubling to
30 min) for as long as the block exists. The reconciler enqueues archive for
every cataloged block whose archive state is `pending` or `failed_retryable`,
that still archives (A6) and has no job, so a lost job or an outage cannot
strand a block; such an entry that no longer archives moves to `not_required`
as in A6 step 1.

Exposed to the settings `health` tab per member and in total: unarchived block
count and bytes, oldest unarchived age, archive goodput against capture,
unreconciled block count (found on disk, not yet in an end state), unattributable
count, and gaps by reason. These are published through the settings change's
JetStream backlog telemetry.

Alarms (through the deduplicated, auto-clearing health-check path in C8, not just a page badge):

- oldest unarchived block older than 1 hour (code default);
- any `failed_terminal` archive entry;
- any unattributable block;
- a block unreconciled for longer than 2 reconciler intervals plus the writer
  retirement time;
- reconciliation paused because the recovery gate is closed or history is
  unresolved, for longer than 1 hour.

### R6. Interaction with reclaim

A block is never reclaimed while it is unreconciled:

- Retention selects catalog entries only (C1-C3), so a block with no catalog
  entry is never a candidate.
- The NVR reclaim endpoint (C6) requires a Core operation bound to a catalog
  entry and the frozen descriptor digest, so it cannot target an unadopted
  block.
- Unreconciled blocks are pinned for capacity eviction (C1, C5): budget and
  age eviction never select them, and if they fill the volume, admission stops
  with a gap.
- The only deletions of footage outside the catalog are the audited
  `unrecoverable` residue disposal (R4 step 5) and an operator's explicit delete
  of an unattributable block, both recorded in `RecordingDisposition`.

### R7. Relation to the pending define-nvr-* changes

- [define-nvr-current-history-reconciliation](../define-nvr-current-history-reconciliation/design.md)
  owns recovery after a deliberate CNPG or volume restore: gate closure, a fresh
  generation and per-storage completion against authoritative history. This
  reconciler is the ordinary-operation counterpart. It runs only while the gate
  is ready for the current generation, pauses (with an alarm) on a storage
  lifetime that awaits that change's completion, never establishes history
  genesis, and never treats missing history as permission. No conflict, but R
  depends on its gate for the restore case.
- [define-nvr-local-copy-registration](../define-nvr-local-copy-registration/design.md)
  keeps `intent_accepted`, local-copy registration and storage qualification
  distinct. A catalog entry here is neither: it does not register a qualified
  local copy, and `local_state = present` means inventory and reachability, not
  qualified protection. Historical freeze produces the same frozen block that
  intent acceptance already requires, so automatic intent delivery and later
  registration work on adopted blocks unchanged.
- **Decided (PD1).** Adoption of a reserved block is not a new recorder
  freezing an unknown block: Core's own reservation is the established
  authority. Adoption of a rotated block is the narrow amendment to the plane's
  local publication contract recorded in PD1; when its proof fails the block is
  unattributable.
- **Decided (PD2).** Unregistered local copies play labelled "provisional",
  with fallback to the verified archive copy; the label is removed once
  local-copy registration exists for the copy's storage lifetime.

## C. Retention and reclaim

All retention runs in Core as bounded Oban jobs. The NVR never deletes on its
own: every deletion is a Core-issued operation bound to one catalog entry and
one disposition record. This keeps holds, retention and catalog state
serialized in CNPG, and means a member disconnected from Core keeps every byte.

### C1. Capacity-driven local tier

Product direction (2026-11-15): keep as much footage locally as the volume
allows and move everything to object storage; the local window is whatever the
volume holds at the current recording rate, possibly minutes, and the operator
is told how long that is. The local tier is therefore a bounded cache with a
byte budget, not a time guarantee.

**What the code does today.** The NVR's byte budget is
`SERVICERADAR_NVR_MAX_SPOOL_BYTES` (default 1 GiB, ceiling 1 TiB,
`config.ex:22`) and its free-space floor `SERVICERADAR_NVR_RESERVE_BYTES`
(default 64 MiB, `config.ex:23`). The chart passes `nvr.maxSpoolBytes` and
`nvr.reserveBytes` through unchanged (`helm/serviceradar/templates/nvr.yaml:199-202`)
with defaults of 1 GiB and 64 MiB against a default PVC of 100 GiB
(`helm/serviceradar/values.yaml:3311-3319`). Nothing derives the budget from the
volume or checks it against the volume. The demo values set a 20 GiB PVC and do
not override the budget (`helm/serviceradar/values-demo.yaml:660-662`), so the
NVR there can use about 5% of its volume. Admission refuses at the budget or at
the floor (`capacity.ex:341-357`); nothing evicts.

**Budget.** The chart sets the install ceiling and default, derived from the
volume; the operator can change the budget and reserve at runtime within those
bounds (C9):

- `nvr.reserveBytes`: when unset, `max(64 MiB, 1% of storage.size)`. This is the
  install floor for the reserve.
- `nvr.maxSpoolBytes`: when unset, `floor(85% of storage.size) - reserve`,
  computed in the chart with the existing `serviceradar.quantityBytes` helper.
  This is the install ceiling and the default budget. The 15% headroom covers filesystem
  metadata, journals and publication records, which the NVR charges against the
  budget but the filesystem also needs room for. An explicit value still wins;
  the chart refuses an explicit budget plus reserve larger than the volume.
- Effective budget at runtime is `min(maxSpoolBytes, used + available - reserve)`
  from the NVR's own measurement (`capacity.ex:290-315`), so a volume shared
  with other data or a smaller filesystem than requested is reported honestly.

At 100 GiB this gives a 1 GiB reserve and an 84.0 GiB budget; at 20 GiB, a
204.8 MiB reserve and a 16.8 GiB budget.

**The 1 TiB ceiling is raised to 1 PiB (decided).** The only thing that depends
on it is the bound itself (`config.ex:22`, checked by `config.ex:55-60`). Budget
arithmetic is Elixir integers, which do not overflow: admission and
publication sums (`capacity.ex:321-357`), the per-reservation charge
(`spool.ex:68-71`) and free space as available blocks times block size
(`disk.ex:48-56`). The chart prints the value with `int64` (`nvr.yaml:200`),
and YAML numbers stay exact up to 2^53 bytes (about 8 PiB). The new ceiling
matches the existing reserve ceiling (`config.ex:23`). What does constrain very
large volumes is block count, not bytes; see A5.

**Watermarks and age ceiling.** Runtime settings in CNPG (E1):
`local_high_water_percent` (default 90) and `local_low_water_percent`
(default 80) of the effective budget, and the maximum local age (default
24 h). The age is a ceiling, "keep at most this long locally", not a floor. It
is stored as an explicit mode plus a value: `max_local_age_mode` is `limited`
or `unlimited`, and `max_local_age_seconds` is required and between 3,600 and
315,360,000 (10 years) when `limited`, and must be NULL when `unlimited`. A
check constraint enforces exactly that pairing, so NULL never means "use the
default" and no magic large number stands in for "forever". The same pattern
is used for every other optional limit in E1.

With `unlimited` and archiving on, only the byte budget evicts local copies:
footage stays locally until usage reaches high water, and the effective window
(C1a) is the budget-bound figure. Archive copies expire independently, by
object retention (C3) or the object reaper (C3a); a local copy outlives its
archive copy as local-only footage until the budget evicts it.

**Eviction with archiving on.** A Core retention job per NVR member reads the
member's `GET /v1/status` every 60 s. A block's local copy is evictable when all
hold: it is cataloged and reconciled (section R); its archive copy is either
`verified` or was deleted by object retention or the object reaper
(`archive_state = deleted`, C3, C3a), or the block is local-only
(`archive_state = not_required`) and the recorded local-only full policy is
`overwrite_oldest` (C2); it is not the copy a hold pins (C4); and the member's
recovery gate and current-history state permit destructive operations. A member
may hold both kinds: a camera policy may be `local_only` while archiving is
enabled for others (E1). "Unarchived" means `archive_state` is `pending`,
`failed_retryable` or `failed_terminal`; a block whose archive copy was deleted
is not unarchived but local only after archive expiry or reaping, and its local
copy is evicted under the same budget and age rules as any other. The job
evicts evictable blocks in one oldest-first order across all evictable local
bytes of the member, whatever their kind, ordered by `timeline_start_us`, with
ties broken by `sealed_at` and then `block_key`:

- when usage reaches high water, until projected usage is at or below low water;
- whenever a block's local age exceeds its age ceiling, when that is `limited`:
  the maximum local age for blocks that archive or did archive, and
  `local_only_max_age` for `not_required` blocks (C2).

Whichever comes first. Each eviction is an audited disposition (C6, C7) with
reason `budget` or `max_local_age`, or `local_only_overwrite` or
`local_only_max_age` for a `not_required` block. Blocks whose archive state is
`pending`, `failed_retryable` or `failed_terminal` are never selected by
either rule. Unarchived and unreconciled footage is never
evicted; a held block keeps its pinned copy (C4). Evicting a local copy whose
archive copy was already deleted removes the last copy; the recorded object
retention or `reap_oldest` selection is the authority for that (C3, C3a). This
is policy-authorized retention after hold checks, which
the plane allows (`add-scalable-camera-recording-plane/design.md:187-193`); the
watermark only decides when.

The span between high water and the budget is the job's reaction margin: at
100 GiB it is 8.4 GiB, about 30 minutes at 40 Mbit/s of capture, against a 60 s
poll. Each pass evicts at most 500 blocks per member.

### C1a. Effective local window

The effective local window is a computed, displayed figure, per member:

```
rate     = max(r15m, r6h)      bytes/s of sealed media on the member
pinned   = unarchived + unreconciled bytes
           + held local copies that are the hold's pinned copy
           + local-only (not_required) bytes unless overwrite_oldest is recorded
window   = (low_water_bytes - pinned) / rate
           capped by the age ceiling when it is limited: max_local_age_seconds
           for archived footage, local_only_max_age_seconds for local-only
           footage
```

- `r15m` is the sum of `media_bytes` of catalog entries sealed on that storage
  in the last 15 minutes divided by 900 s, and `r6h` the same sum over the last
  6 hours divided by 21,600 s, so both are bytes per second. Taking the larger keeps
  the figure conservative for bursty variable-bitrate streams (a busy scene
  raises the bitrate) without letting one quiet quarter-hour inflate it. The
  catalog lags capture by at most one block (270 s), which is acceptable for a
  figure shown in hours or minutes.
- A held local copy is the pinned copy in local-only mode, before its archive
  copy is verified (it is then also unarchived and counted once), and when its
  archive copy had already been deleted by object retention or the reaper
  before the hold was placed. Local copies of
  blocks that are local only after archive expiry or reaping and are not held
  are evictable bytes, not pinned bytes, so they do not shorten the window.
- Local-only (`not_required`) blocks, on a local-only member or on a member
  that also archives, are evictable bytes under `overwrite_oldest` and pinned
  bytes under `stop_when_full` or when no full policy has been recorded. In the
  pinned case the page says that local-only cameras are consuming space that
  cannot be freed, and the window is the time until recording stops at the
  limit. On a member that holds both kinds the page shows the window for each
  kind with its own age ceiling.
- With less than 15 minutes of history, `rate` is the sum of the assigned
  profiles' relay-observed bitrates and the figure is labelled "estimated".
- With no enabled policy on the member the page says "not recording" rather
  than an infinite window. With policies enabled but no ingest in 15 minutes it
  says "no recent ingest" and uses `r6h` if there is one.
- The page shows the window as "local storage holds about N hours (or minutes)
  at the current rate", with the high-water figure as the upper end of the
  range, and says which bound applies: budget, maximum age, or block cap. With
  the maximum local age `unlimited` (or `local_only_max_age` unlimited for
  local-only footage) the figure is the budget-bound one, labelled "until the
  local budget is full"; with `local_only_max_age` limited, the local-only
  figure is capped by it (for example 7 days, not the 56 to 63 days the budget
  alone would allow for one 120 kbit/s camera below).

**What-if before saving.** Editing a recording policy (adding or removing a
camera, changing profile, member or storage mode) or the watermarks shows the
projected window before saving: current rate minus the rates of the affected
policies plus the new profiles' relay-observed bitrates (labelled "estimated";
a profile never streamed shows "unknown until recorded"). The same panel shows
the projected archive throughput needed (about twice the capture rate, upload
plus readback, A6) against measured archive goodput, projected blocks per day
against the block cap, and projected sessions against `SERVICERADAR_NVR_MAX_SESSIONS`.
It warns, but does not block, when the projected window is below the alert
threshold (C8).

**Worked examples** for a 100 GiB volume (84.0 GiB budget, low water 67.2 GiB,
high water 75.6 GiB). Bitrates are assumed, not measured:

| Recording on the member | Rate | Window with archiving (age ceiling 24 h) | Window local-only (`overwrite_oldest`, no age ceiling) | Block cap 4,096 today | Block cap 131,072 (ledger, A5) |
| --- | --- | --- | --- | --- | --- |
| 1 camera, 120 kbit/s | 15 kB/s | 24 h (age ceiling binds; about 1.3 GB used) | about 56 to 63 days | binds first: 4,096 blocks of about 4.05 MB hold about 12.8 days | bytes bind |
| 1 camera, 4 Mbit/s | 500 kB/s | 24 h (age ceiling binds; about 43 GB used) | about 40 to 45 hours | binds first: 4,096 blocks of 12 MiB hold about 28.6 hours | bytes bind |
| 20 cameras, 2 Mbit/s each | 5 MB/s | about 4.0 to 4.5 hours (budget binds) | about 4.0 to 4.5 hours | binds first: about 2.9 hours | bytes bind |

The same twenty cameras on a 20 GiB volume (16.8 GiB budget) hold about 48 to
54 minutes. On today's defaults (1 GiB budget), they would hold about 3.6
minutes, and one 4 Mbit/s camera about 36 minutes.

Where the block cap binds: at 4,096 blocks with blocks of at most 12 MiB, the
NVR can never use more than about 48 GiB, so on a 100 GiB volume the count binds
before bytes at every bitrate. With the ledger's default of 131,072 the count
binds before an 84 GiB budget only when the average block is under about
688 kB, that is, streams under roughly 20 kbit/s; on a 1 TiB budget, under about
8.4 MB, streams under roughly 250 kbit/s, which the 262,144 ceiling halves.

Two limits in the code bear on the twenty-camera example and are worth stating
plainly:

- One NVR member runs at most 16 recording sessions (`config.ex:20`). Twenty
  continuous cameras need two members or a higher ceiling; the what-if panel
  reports this.
- One archive slot per member must move about 80 Mbit/s of provider traffic
  for 40 Mbit/s of capture (A6). "Fast object storage" is necessary but not
  sufficient; if archive goodput falls below capture, unarchived footage
  accumulates, the window shrinks and C5 applies. This is unmeasured.

### C2. Local-only mode: a complete mode with an explicit full policy

Local-only recording is a supported mode in the approved plane design, not a
degraded one: "On-prem + local" keeps the full configured retention on the
recorder's volumes with no cloud dependency, and the deployment must not
provision a bucket, attempt an upload or require provider credentials
(`add-scalable-camera-recording-plane/design.md:8`, `18-21`); local-only treats
its retained filesystem as the archive (`design.md:172-178`); local-only
recording "remains supported without S3" (`design.md:203`); and the plane's
requirement "Recording placement and durable storage are independent"
(`add-scalable-camera-recording-plane/specs/camera-recording/spec.md:23-30`)
requires local-only playback with no bucket. In this change:

- Recording, cataloging, reconciliation, the timeline, playback, holds and
  retention all work with `archive_enabled = false` and no destination. Nothing
  waits on an archive, and archive-only checks (backlog age, archive goodput)
  are not evaluated.
- Every page states the mode plainly: "Local only: no object storage
  configured", with the effective window and the full policy. It is never
  shown as an error, a warning or an unconfigured state. Catalog entries carry
  `archive_state = not_required`.
- An operator with a lot of local disk can keep footage until the volume is
  full by leaving `local_only_max_age` `unlimited` (the default) and choosing
  either full policy.

With no object storage there is no second copy, so capacity-driven eviction
deletes the only copy. It happens only under an explicitly selected policy,
`local_only_full_policy`, deployment-wide:

- `overwrite_oldest`: a ring buffer, the conventional NVR behaviour. At high
  water, Core evicts the oldest cataloged, reconciled, unheld blocks down to
  low water, with disposition reason `local_only_overwrite`. On a member that
  also archives other cameras, `not_required` blocks join the single
  oldest-first eviction order of C1.
- `stop_when_full`: nothing is evicted for space. When the budget is reached
  the NVR's admission refuses (`capacity.ex:348-353`), recording stops with a
  `nvr_refused` gap, and a critical alert is raised. Footage is deleted only by
  the optional age ceiling below or by an operator. Local-only footage then
  counts as pinned bytes (C1a, C9), including on a member that also archives,
  where it can stop recording for every camera on the member.

Recommended default: the UI preselects `overwrite_oldest` and the operator must
confirm it when creating the first local-only policy; that confirmation is
recorded with the actor in the settings revision. When no selection has been
recorded (for example a policy created through the API, or an upgrade), the
behaviour is `stop_when_full`. This applies equally to a `local_only` camera
policy on a deployment with archiving enabled: saving it requires a recorded
full policy, or the settings page explains that those cameras' footage will
fill the member and stop its recording, and the what-if (C1a) shows the effect
on the member's effective window before saving.

Reasoning: the plane design says disk pressure is not deletion authority but an
explicitly selected recording policy is allowed (`design.md:187-193`). A silent
code default of "overwrite" would make pressure the authority, so the
code-level default must not delete. In practice, though, operators without
object storage expect a ring buffer: for surveillance, losing the newest
footage because recording stopped is usually worse than losing the oldest, and
the people most affected by this decision are exactly those with no object
storage. Preselecting it with an explicit, audited confirmation gives them the
conventional behaviour while keeping deletion an operator decision.

Also for local-only:

- The local-only retention target (mode `target` or `none`; default `target`
  of 7 days, bounds 3,600 s to 10 years) is a target, not a deletion age. When
  the effective window is below it, an alert says so with the current figure
  (C8). `none` turns the alert off.
- The local-only maximum age (mode `limited` or `unlimited`; default
  `unlimited`, meaning keep until the volume is full; bounds 3,600 s to 10 years
  when limited) is an optional ceiling for sites that must not keep footage
  longer than a period. When limited, older unheld footage is deleted by age
  with reason `local_only_max_age`.
- Holds pin local copies in this mode (C4), so they block eviction. Held
  local copies filling the budget can therefore happen only in local-only mode
  or, with archiving on, for blocks not yet archive-verified (which are pinned
  as unarchived anyway) or whose archive copy had already been deleted when the
  hold was placed. If held footage alone (plus unreconciled footage, and
  local-only footage that cannot be evicted)
  reaches the budget, nothing can be evicted, so recording stops with a
  `nvr_refused` gap even under `overwrite_oldest`, and a critical alert names
  the held bytes and the holds; the operator must release or export holds. The
  view shows held bytes against the budget so this is visible before it
  happens.
- Until local-copy registration qualifies the storage, local-only footage is
  labelled "local only, storage not qualified", never "archived".

### C3. Object retention: ServiceRadar deletes, provider lifecycle does not

An archive copy is due for deletion when `archived_at + archive_retention_days
<= now()` and no hold covers it. Default 30 days.

Options considered:

| | ServiceRadar deletes | Provider lifecycle rule |
| --- | --- | --- |
| Credential | Needs DELETE on the prefix | None beyond write |
| Catalog agrees with bucket | Yes: deletion is a catalog transition with verified absence | No: objects vanish outside the catalog; drift is found only on read |
| Holds | Honoured: deletion is serialized with holds in CNPG | Cannot be honoured: the provider deletes held objects |
| Configurable from the UI | Yes | Only if ServiceRadar also gets lifecycle-configuration permission, a broader authority than DELETE on one prefix |
| Per-camera retention | Yes | One rule per prefix |
| Provider differences | One DELETE plus HEAD contract to qualify | Lifecycle semantics, timing and versioning vary by provider |

Recommendation: ServiceRadar deletes. It is the only option that satisfies the
product owner's "configurable from the settings UI" and keeps holds meaningful.
It is also what the approved VMS design already chose: application-coordinated
deletion, with provider lifecycle only for safe temporary objects or a proven
delayed-expiration contract (VMS design section 6). Provider lifecycle rules
remain appropriate for incomplete multipart uploads and the `_probe/` residue
from destination tests (settings change D12), and the docs say so.

The settings change assumes the writer credential has no delete permission.
That stays true: deletion uses a third credential role.

- `ArchiveCredentialResolver` gains role `:retention`, purpose
  `camera_archive_retention`, methods `["DELETE", "HEAD"]`, locked to the
  binding's host, bucket and prefix like the others.
- `RecordingArchiveSettings` gains `retention_credential_secret_id` (FK
  restrict, nullable), with the same credential-usage inventory, destroy guard
  and validation as the writer and reader slots. It may reference the same
  stored secret as the writer if that key has delete permission at the
  provider; the method allowlist in the grant is what limits each use.
- With no retention credential selected, object retention is not enforced. The
  view says "Object retention not enforced: no delete credential" and shows the
  growing archive size. Nothing is deleted.

Deletion executor: a core-elx Oban job (`ArchiveRetentionJob`) per due entry,
issuing signed DELETE then HEAD for each of the three objects through
`ServiceRadar.HTTP.EgressClient` with the existing SigV4 signer
(`ArchiveStorageHTTP.sign/6`). It runs in core-elx, not the NVR, because archive
copies must expire even when their NVR member or volume is gone. This needs a
provider egress rule for core-elx: a chart NetworkPolicy value, which is install
topology (settings change open question 11).

Versioned and locked buckets:

- The v1 receipt records ETag but not version (`archive.ex:428-447`). Receipt
  version 2 records each object's version ID (nullable). For v1 receipts the
  job HEADs the object; if it reports a version ID with the receipt's ETag and
  length, it deletes that version. A DELETE without a version on a versioned
  bucket only adds a delete marker, which is not deletion
  (VMS design section 6), so it is never used there.
- If HEAD shows a different ETag or length than the receipt, the job does not
  delete and marks `archive_state = missing` with class `object_changed`.
- A provider refusal from object lock or a legal hold is reported as
  `blocked_by_provider` and retried daily, not hot.

Verified absence: after DELETE, HEAD must answer 404 for the deleted key (or
for the deleted version on versioned buckets). Only then does the entry move to
`deleted`.

Archive retention is also an explicit mode: `limited` (default 30 days, bounds 1
to 3,650 days) or `unlimited` (never delete archive copies). Any limited value
in bounds is valid. When both the archive retention and the maximum local age
are limited and the retention is shorter than the maximum local age rounded up
to whole days, the settings UI shows a warning, not a refusal: archive copies
will then expire while their local copies remain, so that footage keeps a
single local copy for the rest of its local life.

Expiry deletes only the archive copy. When the archive copy of a block whose
local copy is still present expires, the job deletes the archive objects as
above and keeps the local copy; the catalog entry then has
`archive_state = deleted` with `archive_deleted_reason = object_retention` and
`local_state = present`, which the API and the page show as "local only after
archive expiry". From then on the local copy is governed exactly like
local-only footage: it stays until the local budget or the maximum local age
requires eviction (C1), oldest first, and it is evictable, not pinned as
unarchived. It is never re-archived automatically: `deleted` is terminal for
the archive job (C6), and re-archiving would undo the retention the operator
configured. Evicting that local copy deletes the last copy; the configured
object retention, together with the local rules, is the authority for it. A
held archive copy is never deleted by retention (C4).

### C3a. Object-tier capacity budget

Purchased or fixed-size buckets must not make the product break (PD7). The
object tier gets a byte budget symmetric with the local tier.

**Where the budget comes from.**

- Self-hosted: operator settings on `RecordingArchiveSettings` (E1):
  `object_budget_mode` + `object_budget_bytes` (`unlimited` by default, or
  `limited` with at least 1 GiB), `object_high_water_percent` (default 90, 50 to
  95), `object_low_water_percent` (default 80, 40 to high water minus 5) and
  `object_capacity_policy` (`reap_oldest` or `stop_archiving`, recorded with the
  confirming actor and time; required when the budget is limited). As with the
  local-only full policy (PD4) the UI preselects `reap_oldest` and the operator
  confirms it; with nothing recorded the behaviour is `stop_archiving`, because
  deletion needs an explicit authority.
- Hosted: the `recordings` consumer of the applied storage entitlement (stage
  F). Its hard limit is `allocation_bytes` when overage is off, or
  `overage.cap_bytes` when metered; its capacity policy comes from the plan
  terms. The operator fields are then read-only and show the entitlement's
  values. Water marks stay operator settings.

**Usage** is what ServiceRadar wrote: the sum of object lengths in the receipts
of archive copies that are `verified` or `deleting`, for the active binding,
plus the bytes of uploads in flight, maintained in the catalog. It does not
list the bucket (costly, and providers report usage differently); in SaaS the
control plane compares it with the provider's own bucket size (stage F). A
self-hosted bucket shared with other data needs a budget that leaves room for
it. Probe residue (settings change D12) is negligible and excluded.

**`reap_oldest`.** When usage reaches object high water (of the hard limit),
Core deletes archive copies of the oldest blocks first, down to object low
water. Candidates are blocks whose archive copy is `verified`, cataloged,
reconciled and unheld. The reaper deletes only the archive copy: each deletion
uses the retention credential (C3: versioned delete, HEAD 404 re-check) and is
an audited disposition of the archive copy with reason `object_capacity`. Each
pass is bounded (500 blocks) and re-reads usage. Time-based archive retention
still applies (reason `object_retention`); whichever bound an archive copy
reaches first deletes it, and the two reasons stay distinct so the audit and
the display can say which bound binds.

When a reaped block's local copy still exists, it is kept. The catalog entry
records `archive_state = deleted` with `archive_deleted_reason =
object_capacity` and `local_state = present`, shown as "local only after
archive reaping", and the `object_capacity` disposition records that the local
copy remained. From then on that local copy is governed exactly like local-only
footage: it stays until the local budget or the maximum local age requires
eviction (C1), oldest first, and it is evictable, not pinned as unarchived. It
is never re-archived automatically: `deleted` is terminal for the archive job
(C6), and re-archiving would refill the bucket, which the reaper would empty
again, in a loop.

The reaper can delete the last copy of footage: once the local copy has been
evicted, the archive copy is the only one. Selecting `reap_oldest` also
authorizes the later local eviction of blocks whose archive copy was reaped,
which deletes the last copy too. The recorded selection states both, the
settings page says so before the selection is recorded, and the selection is
recorded with its actor (or the plan terms and entitlement revision).

How the reaper treats an archive copy whose local copy still exists (decided by
the product owner). Three options:

| Option | Effect | Problem |
| --- | --- | --- |
| Delete the archive copy alone, keep the local copy as local only | The local copy stays until the local budget or maximum local age evicts it | Footage older than the bucket holds has a single local copy; the page must say so |
| Exclude it from reaping | Only archive copies whose local copy is gone are candidates | With an unlimited local age and a large disk, few or no candidates exist; the object tier overruns its budget, archiving stops, and new footage is single-copy for as long as the local tier takes to fill |
| Reap the whole block, local copy first | The local copy is evicted, then the archive copy is deleted | A small bucket caps all history, even on a large local volume, which contradicts "keep footage locally for as long as it fits" |

Decision: delete the archive copy alone and keep the local copy as local only.
Nothing is stranded, because the local copy stays evictable under the local
rules; nothing is lost silently, because every deletion is an audited
disposition under a recorded policy; and archiving never stops while reapable
archive copies exist. An operator with a lot of local disk keeps local history
for as long as the volume holds it, whatever the bucket's size. Archive copies
whose local copy still exists are reapable and do not count as non-reapable
bytes.

What the page shows: the effective object retention (below) and the effective
local window (C1a) side by side, and, when the reaper has run, "footage older
than about N days exists only on local storage" with the oldest local-only
footage time, so the operator sees which history has a single copy. The total
history kept is the longer of the two figures.

**`stop_archiving`.** When archiving the next block would exceed the hard
limit, archive jobs pause: blocks stay `pending` (not failed), are retried when
space appears (time retention deletes, the budget is raised, holds are
released), and stay pinned locally as unarchived. Recording continues locally
until the local budget fills, then stops with a gap with reason
`archive_capacity_exhausted` (C5). Alerts precede both.

**Held and non-reapable bytes reach high water.** Holds pin verified archive
copies (PD5) and the reaper never deletes them. Non-reapable bytes are held archive
bytes plus uploads in flight. When they alone reach object high water, nothing
can be reaped: new archive uploads pause (as in `stop_archiving`), recording
continues locally, and a critical alert names the held bytes and holds. Between
object low water and high water the calculated T is already 0 (no reapable
history fits under low water), but uploads continue; they pause only at high
water. The
local tier then follows C1 and C5. Releasing a hold, raising the budget or
enabling overage resumes archiving, and the backlog uploads oldest first.

**Calculated retention** (the shared formula; stage F has the test vectors).
Inputs per enabled archive policy c:

- `rate_c`: archived bytes per day from the catalog, the larger of the trailing
  24 h and the trailing 7-day daily mean. With under 24 h of history,
  `nominal_bitrate_c * 86,400 / 8 * 1.02` (CMAF and descriptor overhead),
  labelled "estimated"; a profile never streamed is "unknown until recorded".
- `ret_c`: configured archive retention in days (policy override, else the
  deployment value; `unlimited` is infinity), bounded by the plan maximum in
  SaaS.
- `available = object_low_water_bytes - non_reapable_bytes`.

Oldest-first reaping across cameras produces one common age cutoff T. Solve
`sum_c rate_c * min(ret_c, T) = available` for T; the left side is continuous
and non-decreasing in T, so sort the `ret_c` and solve piecewise. Then:

- capacity days = T; T is infinite when `sum_c rate_c * ret_c <= available` with
  every `ret_c` finite, and T = 0 when `available <= 0`;
- effective retention of policy c = `min(ret_c, T)`;
- binding bound of policy c = `time` when `ret_c <= T`, else `capacity`.

With an unlimited object budget, T is infinite and every effective retention is
the configured one. The page shows, per policy, "configured 30 days, effective
about 15 days (capacity binds)", held bytes, and the hard limit. The policy and
retention tabs run the same calculation with edited inputs before saving
(add cameras at a nominal bitrate, change profiles, change the budget): the
what-if. Saving a configured retention above the projected T is allowed with an
acknowledgement, because rates change; it is refused only above the plan
maximum (stage F).

**Alerts and events.** Checks through `TripwireHealth.record/4`, named
`storage.recordings.<check>`, with the figures in metadata and a link to the
retention tab. They fire before reaping starts:

| Check | Unhealthy when | Severity |
| --- | --- | --- |
| `object_capacity_binds` | effective retention below configured retention for any policy | warning (before the first capacity deletion) |
| `object_days_to_high_water` | projected days until object high water below 7 | warning; critical below 2 |
| `object_used_percent` | usage at or above 75% of the hard limit | warning; critical at 90% |
| `object_overage_active` | usage above `allocation_bytes` with metered overage (stage F) | warning (billing applies) |
| `object_held_exceeds` | non-reapable bytes at or above object high water | critical (archiving paused) |
| `object_archive_paused_capacity` | new uploads paused for capacity | critical |

`held_archive_missing` (C8) also applies.

Each reaper pass that deletes anything also publishes one OCSF event through
`ServiceRadar.Events.OcsfEventPublisher.publish/2`
(`elixir/serviceradar_core/lib/serviceradar/events/ocsf_event_publisher.ex:105`,
family `:camera`) with the bytes and blocks deleted, the oldest remaining
footage time, the resulting effective retention and the binding bound. The
disposition records remain the audit.

### C4. Holds and exports

Retention without holds is unsafe for investigations. This change adds the
minimal hold resource that the VMS requirement "Transactional evidence holds and
export leases" and the local publication contract describe.

`ServiceRadar.Camera.RecordingHold`, table `platform.camera_recording_holds`:
camera, optional profile, `[start_us, end_us)` on the timeline, `kind`
(`investigation` or `export`), reason text, actor, `state` (`pending`,
`accepted`, `released`), released actor and time. A hold covers every catalog
entry whose timeline range intersects it.

Which copy a hold pins (PD5): a hold must keep at least one verified copy.

| Covered entry | Pinned copy | Other copy |
| --- | --- | --- |
| Archive copy verified | Archive copy: not deleted by time retention or the object reaper | Local copy stays evictable by the local budget and age rules |
| Archiving on, archive copy not yet verified | Local copy (it is unarchived, so it is pinned anyway) | none yet; when the archive copy becomes verified, the pin moves to it in the same transaction that records the receipt |
| Local-only | Local copy: not evicted by the full policy or a local-only maximum age | none |
| Archive copy already deleted by retention or the reaper when the hold was placed | Local copy: not evicted by the budget or the maximum local age | none |

A hold whose pinned archive copy is later found `missing` (C3, C6) raises a
critical alert naming the hold; if the local copy still exists at that moment,
the pin moves back to it. A daily bounded job re-checks held archive copies by
HEAD (length, ETag) so a lost object is found while the local copy may still
exist.

Serialization: hold acceptance and deletion intent take the same row locks on
the covered catalog entries. A hold accepted first blocks deletion. A deletion
intent committed first wins: the hold is accepted with those blocks listed as
"unavailable, deletion in progress", never silently included. The NVR has no
hold state because it never deletes on its own; Core's transaction is the
serialization point, which satisfies the local publication rule that a pin
committed first prevents deletion.

Release is explicit and audited. Expiry, disconnection, policy changes and
storage pressure never release a hold. Exports do not exist yet; when they do,
they register `kind = export` holds through the same table.

New permission `devices.cameras.recordings.hold` (create and release holds),
admin by default.

### C5. When nothing is evictable: time-to-full and admission stop

Disk pressure is never deletion authority for unarchived, unreconciled or
pinned held footage (plane design section 5, `design.md:187-193`). With archiving on, an
archive outage means new footage stays unarchived, so the volume fills with
footage that cannot be evicted.

- **Time-to-full** per member:
  `ttf = (effective_budget - used + evictable_bytes) / rate`, where `rate` is the
  C1a rate and `evictable_bytes` are bytes eviction could still free, including
  unheld local copies of blocks that are local only after archive expiry or
  reaping. With the
  archive down, nothing new becomes evictable, so `ttf` falls steadily. It is
  shown on the page and drives alerts at 4 hours (warning) and 1 hour
  (critical) (C8).
- **Admission stop.** When the budget or the reserve floor is reached, the
  NVR's own admission refuses (`:nvr_spool_budget_exhausted` or
  `:nvr_storage_pressure`, `capacity.ex:348-353`; `:nvr_inventory_limit` at the
  block cap). The coordinator records a `nvr_refused` gap, retries admission
  every 30 s, and a critical alert says "recording stopped: local storage full,
  N unarchived blocks waiting". When the archive recovers, verified blocks
  become evictable, eviction frees space at the next pass, and recording
  resumes; the gap closes.
- **Never**: evict unarchived or unreconciled footage or a held local copy
  that is the pinned copy (C4), shorten the
  archive retention, grow the volume, or change destination to hide pressure.

The same rules apply in local-only mode under `stop_when_full`, and under
`overwrite_oldest` when held and unreconciled footage alone fill the budget
(C2).

### C6. Making deletion safe

AGENTS.md requires closing the paths that recreate deleted data before deleting
it, and re-checking after deleting. The writers that could resurrect a deleted
copy, and how each is closed:

| Writer | Hazard | Closure |
| --- | --- | --- |
| `ArchiveBlockJob` | Re-uploads a block whose archive copy was deleted, including one whose local copy remains | Runs only from `pending` or `failed_retryable`; `deleting` and `deleted` are terminal, so a block that is local only after archive expiry or reaping is never re-archived |
| NVR retained-receipt reply | NVR answers a stale `archive-receipt.json` for an object since deleted | Core never requests archive for a terminal entry, so the retained receipt of a local copy that outlived its archive copy is never consulted; the NVR reclaim removes the receipt with the block |
| `receipt_import` (settings change) | Records a receipt for a deleted copy | Receipt rows stay append-only evidence; import never changes catalog state out of a terminal state |
| Catalog registration and reconciliation | Recreates or revives an entry | Registration is create-only on `(storage_id, block_key)`; a database trigger refuses any update of `local_state` or `archive_state` out of `reclaimed` or `deleted` |
| NVR boot recovery / `recover_block` | Recovers a half-deleted block directory | NVR writes a tombstone to a disposition journal (fsynced) before unlinking; boot finishes the unlink and lookup reports `reclaimed`, never `incomplete` |
| Volume snapshot restore | Old blocks reappear on disk | Lookup reports them; Core does not re-register entries in a terminal state and lists them as "orphaned retained bytes" for an explicit operator decision |
| CNPG restore | Catalog shows copies present that were deleted | Reads that fail mark the copy `missing`; retention re-deletion is idempotent; restore follows the current-history reconciliation gate |
| Provider lifecycle on the footage prefix | Objects vanish outside the catalog | Documented as unsupported; reads and the audit (below) mark the copy `missing (removed externally)`, never present |

Inventory accepts only `.storage-id` and 64-character block directories at the
volume root (`disk.ex:19`, `disk.ex:61`) and a fixed file list inside each block
(`disk.ex:9`). The disposition journal is a new known root entry, added to that
check and to the ledger, so a tombstone never makes inventory fail.

Re-checks:

- Local reclaim: after the NVR answers, Core calls lookup; only `reclaimed` or
  `absent` moves the entry to `reclaimed`.
- Object deletion: HEAD 404 per object (C3).
- Retention audit job: daily, a bounded sample (default 200 entries) of
  `reclaimed` and `deleted` copies is re-checked against the NVR and the bucket.
  A copy found present again is reported as an alert and recorded; it is not
  deleted again automatically and its state is not changed back.

### C7. Audit trail

`ServiceRadar.Camera.RecordingDisposition`, table
`platform.camera_recording_dispositions`, append-only (no update, no destroy):
operation ID, catalog entry, copy (`local` or `archive`), reason
(`budget`, `max_local_age`, `local_only_overwrite`, `local_only_max_age`,
`object_retention`, `object_capacity`, `unrecoverable`, `operator_unattributable`),
the settings revision and the effective values used, the hold check result,
for an archive-copy deletion whether the local copy remained,
then one row per step: `requested`, `executed`, `verified_absent`, `failed`
(bounded class). Settings changes are already audited by AshPaperTrail on
`RecordingArchiveSettings`; `CameraRecordingPolicy` and `RecordingHold` get the
same. Disposition rows are kept for the audit retention period configured for
security audit history, and at least as long as the CNPG backup horizon.

### C8. Storage events and alerts

Mechanism: the existing `ServiceRadar.Observability.TripwireHealth.record/4`
(`elixir/serviceradar_core/lib/serviceradar/observability/tripwire_health.ex:26`).
It records through `HealthTracker.record_health_check/3`, which deduplicates
unchanged states, puts transitions on the health timeline, and publishes a
`health.state_change` OCSF log through JetStream that alert rules can match.
Recording the check healthy again clears it. Issue
[#6359](https://github.com/carverauto/serviceradar/issues/6359) ("Operator
notices: deduplicated, auto-clearing platform notices") lists
`TripwireHealth.record/4` as a notice producer, so when it lands these checks
appear behind the topbar bell with no change here. There is no OpenSpec change
for #6359 yet; this change does not depend on it and does not invent a parallel
notice store.

Checks, one per member (`nvr.<storage_id>.<check>`), evaluated by the retention
job each pass:

| Check | Unhealthy when | Severity |
| --- | --- | --- |
| `local_high_water_pinned` | usage is above high water and nothing is evictable | warning; critical at the budget |
| `local_window_low` | effective window (C1a) below `local_window_alert_seconds` (default 1 h) with archiving on | warning |
| `time_to_full` | `ttf` below 4 h | warning; critical below 1 h and when admission has stopped |
| `archive_backlog_age` | oldest unarchived block older than 1 h (R5) | warning; critical when `ttf` is also below 4 h |
| `local_only_target` | local-only effective window below `local_only_retention_target_seconds` | warning |
| `held_bytes_fill` | held local copies that are the pinned copy (local-only mode, not yet archive-verified, or archive copy deleted before the hold), local-only footage that cannot be evicted (no `overwrite_oldest` recorded), plus unreconciled bytes above local high water | warning; critical at the budget |
| `held_archive_missing` | a held archive copy failed its re-check (C4) | critical |
| object-tier checks | see C3a (`storage.recordings.*`) | |

Section R5's reconciliation alarms use the same mechanism. Each check carries
the figures (window, rate, used, budget, `ttf`, oldest unarchived age) in its
metadata and a link to `/settings/recording?tab=health`. Thresholds that are not
settings are code constants.

Later, optional: a ServiceRadar agent on the storage host can add the
underlying disk's latency, errors and health through its normal sysmon metrics
over JetStream, and the health tab can show them beside the NVR figures. With
replicated storage (Longhorn, Ceph) a volume spans several hosts' disks, so
that signal is advisory context, never an input to eviction or admission, and
nothing here depends on an agent being present.

### C9. Operator-set budget and reserve at runtime

Today the budget and reserve reach the NVR only as process environment from the
chart (`config.ex:22-23`, `templates/nvr.yaml:199-202`), read once at boot. The
project rule is that operator-changeable behaviour is not Helm-only: the hosted
control plane renders tenant values, so runtime choices need CNPG settings with
code defaults.

**Where the setting lives.** Per member, keyed by storage UUID (the storage
lifetime, not the pod name), in a new `ServiceRadar.Camera.NVRStorageSettings`
resource (PaperTrail audited): `budget_mode` (`install_default` or `custom`) with
`budget_bytes` required only when `custom`; `reserve_mode` likewise with
`reserve_bytes`; and a monotonic `revision`. Per member rather than
deployment-wide because these are byte quantities of one volume, and members can
have different volumes; a deployment-wide byte value would be wrong for all but
one of them. The watermarks and ages are percentages and durations, which do
carry across members, so they stay deployment-wide (E1).

**Bounds, checked by Core when saving and again by the NVR when applying:**

- budget at most the install ceiling (`SERVICERADAR_NVR_MAX_SPOOL_BYTES`) and at
  most the measured volume capacity minus the applied reserve;
- budget at least the bytes currently pinned on the member (unarchived,
  unreconciled, held local copies that are the hold's pinned copy, and
  local-only footage unless `overwrite_oldest` is recorded, as in C1a; held
  blocks whose archive copy is verified pin that copy, not local bytes), from
  the catalog, checked by Core at save time, so an
  operator cannot set a budget that eviction could never reach; and at least
  two block reservations (about 36 MiB) so admission can work at all;
- reserve at least the install reserve and at most 10% of the volume.

Lowering the budget below current usage is allowed (above the pinned floor). It
only stops admission until eviction brings usage under the new high water and
makes more blocks evictable; the NVR never deletes because a budget changed.

**Delivery.** A Core Oban job (`NVRStorageSettingsSyncJob`) pushes the desired
settings to each member whenever its desired revision differs from the applied
revision reported in `GET /v1/status`, over the existing pinned mTLS and bearer
channel: `PUT /v1/storage/settings` with a canonical JSON body of at most 1 KiB:
`version: 1`, `storage_id`, `recovery_generation`, `revision`, `budget_bytes`,
`reserve_bytes` (the resolved values; `install_default` resolves to the install
values). The NVR:

1. checks storage UUID and recovery generation like the archive route, and that
   `revision` is greater than its persisted revision (an equal revision with
   identical bytes is an idempotent success; a lower one is refused as stale);
2. checks the bounds above against its own install values and a fresh volume
   measurement;
3. writes `.storage-settings.json` beside `.storage-id` (temporary file, fsync,
   rename, directory fsync), charged to the control reserve; inventory accepts
   the new root entry (`disk.ex:16-19` today rejects unknown root entries);
4. applies it to `Capacity` state atomically, so the next admission and the next
   writer pressure check use the new values without a restart;
5. reports `applied_budget_bytes`, `applied_reserve_bytes`,
   `applied_revision`, the install ceiling and floor, and volume capacity in
   `GET /v1/status`.

At boot the NVR loads the persisted file if it names its own storage UUID and
passes the bounds against the current install values; otherwise it uses the
install values and reports `settings_state: install_default` or
`refused_on_boot` with the reason. A chart change that lowers the ceiling below
a persisted budget therefore takes effect at once, and the UI shows the
difference.

The settings page shows desired versus applied per member: "applied",
"pending" (with age), or "refused: <reason>". Refusal and a pending state older
than 10 minutes raise a health check (C8).

**Before C9 lands.** The chart-derived budget and reserve (C1) are what the NVR
uses. The settings page shows them per member, read-only, labelled "install
value", with a pointer to the chart value that changes them. Watermarks, ages, full
policy and alert thresholds already work, because they are evaluated by Core,
not by the NVR.

## D. Unified timeline playback

### D1. Surface

One surface per camera: `/cameras/:camera_source_id/recordings` gains a Timeline
mode backed by the catalog (settings change open question 9 assumed
convergence). The existing publication list stays for `ArchiveUploads`
recordings until those are migrated or retired.

API (new routes, same authentication, session and security plugs as the
existing archive media API):

| Route | Purpose |
| --- | --- |
| `GET /api/cameras/:id/timeline?from=&to=&profile=` | Coverage buckets, blocks and gaps for a window; bounded |
| `GET /api/cameras/:id/timeline/playlist.m3u8?from=&to=&profile=&source=` | HLS VOD playlist across blocks |
| `GET /api/cameras/:id/timeline/blocks/:entry_id/init?source=` | Initialization bytes |
| `GET /api/cameras/:id/timeline/blocks/:entry_id/fragments/:index?source=` | One fragment |

`source` is `auto` (default), `local` or `archive`. Forced sources implement the
settings change's "Source-forced recorded playback" requirement: no fallback.
Clients never supply object keys, offsets or provider URLs.

New routes rather than reusing `/recordings/:id/...`: those are bound to the
`ArchiveUploads` publication proof chain (archive-reads.md); weakening them to
accept NVR receipts would change their meaning.

### D2. Playlist construction

For an authorized window (at most 60 minutes, 2,048 segments and 256 KiB of
playlist), the server reads catalog entries and their frozen descriptors and
emits a version 7 VOD playlist:

- one `EXT-X-MAP` per distinct `init_sha256` (consecutive blocks with the same
  init reuse one map URI);
- one segment per descriptor fragment, with exact decimal durations as the
  single-block serializer does today;
- `EXT-X-DISCONTINUITY` where the init changes, the clock epoch changes, a gap
  lies between blocks, or the fMP4 timestamps of consecutive blocks are not
  continuous (A4);
- `EXT-X-PROGRAM-DATE-TIME` at the start of each discontinuity sequence, from
  the time basis. The timeline JSON carries the basis label; the playlist tag
  is used only to drive the UI clock;
- a finite end marker. The player requests the adjacent window before the end
  of the current one, so continuous scrubbing crosses windows without a manual
  step.

Gaps are not encoded as fake media. Whether to emit `EXT-X-GAP` placeholders
is a player qualification item for the pinned hls.js; until qualified, the
player jumps over the discontinuity and the timeline bar shows the gap.

Playlist assembly does no storage I/O, like today's serializer.

### D3. Copy resolution

For each fragment request in `auto` mode:

1. If the entry's `local_state = present`, read from the owning NVR member with
   a short first-byte deadline (2 s).
2. Otherwise, or if the local read fails with unavailable, timeout or not found,
   and `archive_state = verified`, read the same fragment from the archive copy.
3. Otherwise answer unavailable (409) with the reason.

Both copies are checked against the fragment's SHA-256 in the frozen descriptor
before release, so the bytes are identical whichever copy served them. A local
read that fails integrity is not silently replaced: it is reported, the copy is
marked `missing` with class `local_integrity`, and the archive copy serves only
if verified. Each response carries `X-Recording-Copy: local` or `archive`.

Local copies whose storage lifetime has no local-copy registration and current
qualification are labelled "provisional" (PD2): the timeline marks them, and the
header reads `local; provisional`. The label is removed per copy once
registration exists for its storage lifetime.

### D4. Bounded reads and read-ahead

Reuses the plane's object playback section: per-playback and aggregate limits,
seek cancels obsolete prefetch, no whole-recording restore.

- Archive fragments are ranged GETs inside the packed `media.m4s` object at the
  descriptor's offset and length (at most 4 MiB). Init is one GET of
  `init.mp4`.
- Per playback session: at most 4 fragment requests in flight. Per web-ng node:
  at most 64 in flight, configurable as an install bound. Excess answers 503
  with `Retry-After`.
- Player read-ahead: forward buffer target 30 s for timeline playback (the
  single-block player uses 8 s), back buffer 30 s. Selected from startup and
  seek behavior to be measured, not guaranteed.
- A shared fragment cache is a later item; when added it follows the plane's
  cache rules (fresh authorization on every hit, no recorder spool use).
- Coverage queries aggregate catalog rows into at most 1,440 buckets per
  request in SQL; a window of more than 31 days is refused.

### D5. Local read path

web-ng reads local fragments from the owning NVR member over a new read
listener: `GET /v1/blocks/<id>/init` and `GET /v1/blocks/<id>/fragments/<n>`
with the expected descriptor SHA-256. It uses mTLS with a client pin and a
read-purpose bearer token separate from the ingest token, both workload
credentials under infrastructure custody. Reads run in a separate playback read
pool (default 8 slots, 10 s each), so playback cannot starve archive,
inventory or verification reads, which keep the existing 4-slot pool. The chart
adds a NetworkPolicy rule from web-ng pods to the read port only.

This is new relative to the settings change's D7 ("web-ng never contacts an
NVR"), which governs operator operations. Playback bytes must reach the browser
through web-ng; routing them through core-elx would move media over ERTS
distribution, which the recording design avoids.

### D6. Archive read path, credentials and egress

Archive copies must play when the NVR member or its volume is gone. The reader
is the existing isolated archive reader
(`ServiceRadarCoreElx.CameraStorage.Service.main_read/0`, Helm
`archiveReader.enabled`), which already does identity-bound ranged GETs with
digest checks under a single admission slot.

Today that reader serves one fixed binding with a mounted credential
(archive-reads.md, "Isolated installation"). Operator destinations and
Cloud-delivered destinations (F7) keep their credential in the CNPG inventory.
The reader gains a per-request credential mode for those bindings that mirrors
the NVR archive contract:

- web-ng resolves the `:reader` grant (HEAD, GET) for the entry's binding
  through `ArchiveCredentialResolver` (falling back to the writer credential in
  the reader role when no reader credential is set, as the settings change
  specifies) and sends it with the exact read plan (destination, key, version
  if known, ETag, offset, length, SHA-256) in one request;
- the reader holds the credential only for that request and never writes, logs
  or returns it;
- the reader validates destination shape like the NVR does and accepts only
  the `<prefix>/<storage_id>/<block_id>/(init.mp4|media.m4s)` key family.

The credential is in web-ng memory for the duration of one request, as it is in
Core for `NVRArchive.archive_block/5` today. This is a deliberate trade-off
against moving bytes through another hop; see open question 2. The reader's
admission grows from one slot to an install bound (default 8). Its provider
egress uses the existing reader NetworkPolicy values.

### D7. Authorization and audit

Every timeline, playlist, init and fragment request requires
`devices.cameras.recordings.view` and fresh Source scope, repeated before bytes
are released, as the archive reader does today. Live-video permission alone is
not enough. A forced source does not need extra permission.

Audit: one append-only `RecordingAccessAudit` row per playlist window issued
(actor, camera, profile, window, source mode, time basis) and per hold
operation. Fragment requests are not audited individually; they are covered by
their window. Denied requests are logged with class only.

### D8. What investigators see

- A day or multi-day coverage bar per camera: footage local and archived,
  archive only, local only (not yet archived), local only after archive expiry
  or reaping (shown as existing only on local storage; evictable local bytes,
  never counted as unarchived), gap with reason, not scheduled, and deleted by
  retention.
- Time labels with the basis ("received 14:03:12") and a marker where time was
  re-anchored.
- The copy serving the current fragment, from `X-Recording-Copy`, read by the
  player's loader.
- Holds placed on the timeline and their state.

### D9. Later items

- Multi-camera synchronized scrubbing: one clock across N players, aligned by
  the stored basis and labelled with it; cameras with different bases are
  aligned with a warning.
- `camera_reported` time basis from RTCP (section T).
- Shared fragment cache.
- Exact clip export (VMS design section 6).

## S. Stored bytes and request counts

The product owner asked to "compress as much of this as possible, maybe using
zstd". The following is reasoning from the formats; nothing here was measured.

What zstd would not save:

- H.264 slice data is already entropy-coded (CAVLC or CABAC). Its output is
  close to random from a general-purpose compressor's point of view, so zstd
  at any level is expected to save little on `media.m4s`, which is nearly all
  of the stored bytes.
- Compressing media objects would also break things that work today: archive
  playback reads fragments by byte range inside `media.m4s`, the archive
  receipt and readback verify the SHA-256 of the stored bytes, and HLS
  serves the fragments as they are. Seekable zstd framing could restore range
  access, but at the cost of a new container format, CPU on every read and a
  changed verification contract, for an expected saving that is small.

What zstd could save: `descriptor.json` and the CMAF box headers are
compressible, but they are a small fraction of each block (a descriptor is tens
of kilobytes against tens of megabytes of media). Postgres already compresses
large JSON values when it stores them out of line, which covers the descriptor
copy in `RecordingBlock`. This change therefore specifies no zstd for media or
archive objects.

Levers that do reduce stored bytes:

1. **Recorded profile per policy.** Bytes scale with the recorded profile's
   bitrate. The policy names the profile; the view shows observed bitrate and
   estimated bytes per day for each relay-eligible profile before saving.
2. **Retention per tier.** Two policies on one camera, for example the main
   profile with short object retention and a lower-bitrate profile with long
   object retention, use the per-policy `archive_retention_days_override`.
   Each profile is a separate source session, as the plane design allows.
3. **Camera encoder settings.** Bitrate caps, GOP length and smart-codec modes
   are camera configuration, outside this change; the view surfaces the
   resulting bitrate.
4. **H.265 passthrough (later).** H.265 is commonly reported to need noticeably
   less bitrate than H.264 for similar quality; that is a general claim, not a
   measurement here. Packaging admits only H.264 today (`descriptor.ex:16`),
   and browser playback of HEVC is a separate qualification gate (VMS design
   section 2). It is a later item.
5. **Provider storage class (later).** A per-destination storage class for
   archive PUTs needs a Longshore PUT option and a destination field. Classes
   with minimum storage durations or retrieval fees interact badly with short
   retention and with playback, so the view would have to show those terms.

Levers that reduce request counts:

1. **Longer blocks.** Each archived block costs 3 PUT and 3 HEAD plus readback
   GETs (one each for init and descriptor, and one per 4 MiB of media, so at
   most 5 for a 12 MiB block). Going from the 25 s ceiling before #6660
   (about 20,700 PUT and HEAD per camera per day) to the A1 sizing cuts that to about 1,920
   for streams under roughly 370 kbit/s, about 5,150 at 1 Mbit/s and about
   10,300 at 2 Mbit/s, and leaves it unchanged (about 20,600) at 4 Mbit/s,
   where 12 MiB still closes a block in about 25 s. Readback GETs follow bytes
   and are unchanged. Higher-bitrate streams need blocks above 16 MiB (A8).
2. **Shared init objects (later).** `init.mp4` is usually identical across a
   run's blocks. Storing it once per run would remove one PUT, HEAD and GET per
   block, at the cost of an archive layout change and a shared dependency for
   deletion.
3. **Readback policy.** Full readback doubles the bytes moved per block and can
   be billable egress. Replacing it with a provider-verified SHA-256 checksum
   would halve that, but only after the provider's checksum behavior is
   qualified. Open question 1; default is to keep full readback.

Manifests are stored compactly: the catalog row stores the summary (ranges,
counts, digests), and the fragment map lives once in the frozen descriptor.

## E. Settings and UI surface

### E1. Settings

Runtime choices live in CNPG with code defaults, never Helm-only. Names that
already appear in the settings change are reused, not redefined. Every
optional limit is stored as an explicit mode plus a value, with a check
constraint that the value is present and in bounds exactly when the mode needs
it; NULL never means "default" and no sentinel number means "unlimited". Every
row below is editable on `/settings/recording`.

"Applied" says when a saved change takes effect. Core-evaluated settings apply
on the next retention pass (at most 60 s) or the next job; NVR-applied settings
apply when the member acknowledges them (C9).

Deployment-wide, on `RecordingArchiveSettings` (singleton, PaperTrail audited):

| Setting | Default | Bounds | Unlimited / off allowed | Applied |
| --- | --- | --- | --- | --- |
| `archive_enabled` | false | | n/a | next block registration and archive job |
| `local_high_water_percent` | 90 | 50 to 95 of the member's applied budget | no | next retention pass |
| `local_low_water_percent` | 80 | 40 to high water minus 5 | no | next retention pass |
| `max_local_age_mode` + `max_local_age_seconds` | `limited`, 86,400 | 3,600 to 315,360,000 (10 years) when limited | yes, `unlimited` | next retention pass |
| `local_window_alert_mode` + `local_window_alert_seconds` | `enabled`, 3,600 | 60 to 31,536,000 when enabled | yes, `disabled` | next retention pass |
| `local_only_full_policy` (+ confirming actor and time) | none recorded, which behaves as `stop_when_full` | `overwrite_oldest`, `stop_when_full` | n/a | next retention pass |
| `local_only_target_mode` + `local_only_retention_target_seconds` | `target`, 604,800 | 3,600 to 315,360,000 when `target` | yes, `none` | next retention pass |
| `local_only_max_age_mode` + `local_only_max_age_seconds` | `unlimited` (keep until the volume is full) | 3,600 to 315,360,000 when limited | yes, `unlimited` | next retention pass |
| `archive_retention_mode` + `archive_retention_days` | `limited`, 30 (in SaaS, the entitlement's `default_days`) | 1 to 3,650 when limited, at most the plan's `max_days` in SaaS; a warning, not a refusal, when shorter than a limited maximum local age (C3) | yes, `unlimited`, except when a plan maximum is set | next retention pass |
| `retention_credential_secret_id` | none | an enabled `s3_compatible` secret | none selected means object retention is not enforced | next retention pass |
| `object_budget_mode` + `object_budget_bytes` | `unlimited` | at least 1 GiB when limited; read-only from the storage entitlement in SaaS (F3) | yes, `unlimited` | next retention pass |
| `object_high_water_percent` | 90 | 50 to 95 | no | next retention pass |
| `object_low_water_percent` | 80 | 40 to high water minus 5 | no | next retention pass |
| `object_capacity_policy` (+ confirming actor and time, or entitlement revision) | nothing recorded, which behaves as `stop_archiving` | `reap_oldest`, `stop_archiving`; required when the budget is limited; fixed by plan terms in SaaS | n/a | next retention pass |

Per NVR member, on `NVRStorageSettings` keyed by storage UUID (C9):

| Setting | Default | Bounds | Unlimited allowed | Applied |
| --- | --- | --- | --- | --- |
| `budget_mode` + `budget_bytes` | `install_default` (chart value, C1) | at least the pinned bytes and two block reservations; at most the install ceiling and the measured volume capacity minus the reserve | no | on the member's acknowledgement; shown as desired versus applied |
| `reserve_mode` + `reserve_bytes` | `install_default` | at least the install reserve; at most 10% of the volume | no | on the member's acknowledgement |

Per camera and profile, on `CameraRecordingPolicy`:

| Setting | Default | Bounds | Unlimited allowed | Applied |
| --- | --- | --- | --- | --- |
| `mode` | `off` | `off`, `continuous` | n/a | assignment transition (A3) |
| `stream_profile_id` | none | relay-eligible profile | n/a | assignment transition |
| `nvr_member` | none | configured member | n/a | assignment transition |
| `storage` | `local_and_archive` when archiving is enabled, else `local_only` | `local_and_archive`, `local_only`; `local_only` is allowed while archiving is enabled and its blocks follow the local-only full policy (C2); saving it without a recorded full policy shows that its footage will fill the member, with the what-if window; a block archives only when archiving is enabled and this is `local_and_archive` (A6) | n/a | next block |
| `archive_retention_override_mode` + `archive_retention_days_override` | `inherit` | 1 to 3,650 when limited | yes, `unlimited` | next retention pass |
| `policy_revision` | | | | |

Install values (chart or environment; workload resources, the settings change's
D3 classification). Where an install value also has a runtime setting, the
install value is the ceiling or floor and the default, and the UI shows it:

| Install value | Default | Role |
| --- | --- | --- |
| `nvr.maxSpoolBytes` | 85% of `nvr.storage.size` minus the reserve | ceiling and default for the runtime budget; NVR ceiling raised to 1 PiB |
| `nvr.reserveBytes` | max(64 MiB, 1% of `nvr.storage.size`) | floor and default for the runtime reserve |
| `SERVICERADAR_NVR_MAX_BLOCKS` | 131,072 (ceiling 262,144 on flat volumes) | block cap (A5) |
| `SERVICERADAR_NVR_MAX_SESSIONS`, `SERVICERADAR_NVR_MAX_DURATION_MS`, `SERVICERADAR_NVR_MAX_BLOCK_FRAGMENTS` | chart | recording limits (A1, A2) |
| NVR playback read slots, archive reader slots, web-ng fragment in-flight limit | 8, 8, 64 | read limits (D4-D6) |
| provider egress rules for core-elx and the archive reader | none | network policy (C3, D6) |

Constants in code, not settings: block soft and hard bounds (A1, A4), handover
inbox size, archive retry schedule, rate windows (15 min and 6 h), time-to-full
alert thresholds (4 h and 1 h), the 60 s retention poll, playlist window limits
and coverage bucket limits. They are engineering bounds and can become settings
only with a product need.

### E2. Composition with add-nvr-operator-settings

On `/settings/recording`:

- `policy` tab (that change's Stage B): the per-camera policy table above, with
  the what-if panel (C1a) before saving: projected local window, archive
  throughput needed against measured goodput, blocks per day against the cap,
  and sessions against the member's limit.
- `recorders` tab (that change's Stage A): per member, the budget and reserve
  with desired versus applied (C9), the install ceiling and floor, volume
  capacity, and "local storage holds about N hours (or minutes) at the current
  rate". Before C9 lands the budget and reserve are shown read-only as install
  values.
- `retention` tab (new, added to that view's `supported_tabs/0`): watermarks,
  maximum local age (with "no limit"), alert threshold, local-only full policy
  with its confirmation, local-only target and maximum age (with "keep until
  the volume is full"), archive retention (with "no limit"), and the object
  budget, object watermarks and object capacity policy with the effective
  object retention beside the configured one (C3a); the `reap_oldest`
  confirmation states that it can delete the last copy, including by later
  local eviction of blocks whose archive copy was reaped, and the tab shows
  how much footage exists only on local storage. An archive retention
  shorter than a limited maximum local age shows a warning. Each save
  previews what the change would evict. This tab is fully usable with
  archiving off; the archive fields then read "not used: local only".
- `archive` tab: adds retention credential selection next to the writer and
  reader slots. With archiving off it states "Local only: no object storage
  configured" as a normal state, not an error.
- `health` tab: archive backlog (that change's requirement) with unarchived
  count, bytes and oldest unarchived age; reconciliation status (unreconciled,
  unattributable, last pass, paused reason) and alarms (R5); retention status
  (blocks due, blocks blocked by holds, last pass, failures); per member
  "local storage holds about N hours (or minutes) at the current rate" with the
  binding bound (budget, maximum age or block cap), used and pinned bytes
  against the watermarks, time-to-full, and current storage alerts (C8); gaps
  in the last 24 h by reason; inventory ledger state.
- `cameras` tab: the block list gains catalog state and links into the
  timeline.

Refinements to that change, which whichever change is implemented second
applies before archive:

- Its requirement "Runtime recording policy and hot retention settings" makes
  the 24 h hot window a minimum ("reclaim a local block only after its
  retention window has elapsed"). Under the capacity-driven tier (C1) the
  window is a ceiling and budget eviction may reclaim verified-archived blocks
  sooner. This change uses a new field, `max_local_age_seconds`, rather than
  giving `hot_retention_seconds` the opposite meaning. The requirement's other
  rule is kept, narrowed: a block whose archive copy is `pending`,
  `failed_retryable` or `failed_terminal` is never reclaimed by age. A local
  copy that is local only after archive expiry or reaping has no verified
  archive copy and is still reclaimed by the maximum local age and by the local
  budget (C1).
- Its D13 says that in local-only mode "the same field is the archive
  retention itself". This change uses the explicit full policy and target in
  C2 instead.
- The same requirement and D13 require "the absence of holds" before a local
  block is reclaimed. Under PD5 a hold pins the archive copy once it is
  verified, so a held block's local copy may be evicted.
- Its D3 table and open question 6 bound the hot window to 1 hour to 30 days;
  this change allows up to 10 years or unlimited.
- Its D9 `NVRArchiveReceipt` parses name, key, length, SHA-256 and ETag; receipt
  version 2 here adds a per-object version ID (C3).
- Its forced-source playback puts `source=` on the `/recordings/:id` playlist;
  this change puts it on the timeline routes (D1) with the same meaning.
- Its view's `supported_tabs/0` gains `retention`; its `recorders` tab gains the
  per-member budget (C9); Cloud-delivered destinations and credentials are
  read-only there (F7), which is its open question 3's default.

The hold UI lives on the camera Timeline, not in Settings.

## F. SaaS storage entitlements

Source: the control-plane storage-entitlements findings and the companion
control issue (to be filed in `carverauto/serviceradar-control`, draft title
"cold-storage pool with per-consumer allocations, runtime storage entitlement
push and usage metering"). That issue owns the control plane's work: the
per-tenant cold-storage pool, per-consumer allocations and their floors, the
portal split with its 24 h pending decrease, provider bucket sampling,
metering, billing and notices. This stage specifies only what the product
must do. It depends on control issue work where marked, and on control #182
for the recordings bucket and keys.

The product never models tenants. It receives one document, "this
deployment's storage entitlement", with one entry per consumer it runs.

### F1. The entitlement contract

Schema version 1. Unknown fields and versions are refused.

| Field | Meaning |
| --- | --- |
| `schema_version` | 1 |
| `deployment_ref` | This deployment's reference; a mismatch is refused |
| `revision` | Strictly increasing; an exact replay is idempotent, a lower revision is refused (rollback is a new, higher revision) |
| `issued_at` | Issue time, for display |
| `consumers.recordings.enabled` | Whether recordings may use object storage |
| `consumers.recordings.allocation_bytes` | Bytes allocated to this deployment's recordings bucket |
| `consumers.recordings.overage` | `{"mode": "off"}` or `{"mode": "metered", "cap_bytes": N}` |
| `consumers.recordings.capacity_policy` | From the plan terms; `reap_oldest` in SaaS |
| `consumers.recordings.retention` | `max_days` (null means no plan maximum) and `default_days` |
| `consumers.recordings.limits.max_recording_cameras` | Null means no camera limit |
| `consumers.recordings.pending` | Optional `allocation_bytes` and/or `retention.max_days`, with `effective_at` |
| `consumers.warehouse` | Same shape; consumed by the separate StarRocks follow-up, not this change |

On a hosted install a consumer missing from the document is treated as
`enabled: false`. A self-hosted install has no entitlement and is unbounded:
nothing in this stage applies, and the operator settings of C3a are the only
object budget.

The product stores the applied document in a CNPG singleton
`ServiceRadar.Storage.StorageEntitlement` (`id = 'deployment'`, PaperTrail
audited): revision, canonical SHA-256, applied time, `issued_at` and the
per-consumer fields, plus the pending block. It is written only by the
entitlement route. Self-hosted operators set their object budget on
`RecordingArchiveSettings` (C3a), not on this row.

### F2. Delivery

- Routes on the existing private control-plane listener (web-ng port 4001,
  absent from public Services and Gateway routes, `elixir/web-ng/lib/serviceradar_web_ng_web/control_plane_runtime_router.ex:1-7`):
  `PUT /v1/storage/entitlement` with the document, and
  `GET /v1/storage/entitlement` returning the applied revision, digest and
  per-consumer effective state (hard limit, policy, effective retention bounds,
  pending change).
- Authentication: a new purpose `entitlements`, a token domain-separated from
  `account` and `media`, presented in `X-ServiceRadar-Control-Plane-Authorization`
  with `X-ServiceRadar-Deployment-Ref` and `X-ServiceRadar-Entitlement-Generation`,
  checked by the existing control-plane runtime auth plug
  (`elixir/web-ng/lib/serviceradar_web_ng_web/plugs/control_plane_runtime_auth.ex`).
  The `media` token is not reused because the warehouse consumer is not media.
- No Helm value carries any entitlement field. The only install-time signal is
  the existing `hostedRuntime.contractVersion`: when present, the product holds
  archive admission (blocks stay `pending`, recording continues locally) until
  an entitlement has been applied, and shows "waiting for storage entitlement".
- Version gate: the routes ship in a qualified product release. Control decides
  which tenants are pushed to with a `storage_entitlement` chart capability and
  an explicit version list (control issue). The product does not infer
  capability from anything else.
- Control pushes on provisioning and re-pushes whenever its revision is ahead
  of the applied revision from GET (control issue).

### F3. How the entitlement binds Stage C and E settings

- **Object budget:** read-only, from `allocation_bytes` (overage off) or
  `overage.cap_bytes` (metered). The page shows "allocation 500 GB" (and the
  cap) labelled as set by the plan. Water marks remain operator settings.
- **Capacity policy:** fixed by the plan terms (`reap_oldest`), recorded with the
  entitlement revision instead of an operator; the operator cannot select
  `stop_archiving` on a hosted install in the first release.
- **Archive retention:** bounded by `retention.max_days`; `unlimited` is
  unavailable when a maximum is set; lowering is always allowed. The field and
  each per-camera override say "limited by your plan". When a new revision
  lowers `max_days` below a stored value, the stored value is kept and the
  effective value is the minimum ("configured 400 days, effective 365 days,
  plan maximum").
- **Recording cameras:** `max_recording_cameras` bounds enabled continuous
  policies; the policy form refuses the next one with "limited by your plan".
- **Credential and destination slots** for Cloud-delivered values are read-only
  (F7).
- **Reaping order:** reaping under an entitlement follows C3a: archive copies
  only, oldest unheld blocks first; a local copy that still exists is kept as
  local only after archive reaping and is evicted later by the local rules.
  Archive copies whose local copy still exists are therefore reapable and are
  not counted in `non_reapable_bytes` (F5), which is what the control plane's
  allocation floor is computed from. The findings document proposed skipping
  such copies instead; this change keeps its own decision (C3a) for the reasons
  recorded there. The local volume is not part of the allocation, so local-only
  footage after reaping costs the pool nothing.
- Local budget, reserve, local ages and the local-only policy are not part of
  the entitlement: the local volume is install topology, which control already
  renders and bills as hot storage.

### F4. Pending changes

A `pending` block (a lower allocation or a lower `max_days`) is shown on the
retention tab before it applies: the new value, its `effective_at`, and the
calculated consequence from F5 ("recordings would keep about 9 days instead of
15; about 210 GB of the oldest footage will be deleted"). The product applies
it at `effective_at` (database time); a later revision without the pending
block cancels it. The product never shortens the delay; the 24 h delay and the
confirmation belong to control. After it applies, the reaper works down
gradually, oldest first, under C3a.

### F5. Calculated retention and the usage report

The calculated retention formula is the one in C3a, specified once here and
satisfied by both sides. Test vectors (bytes and days; `GB` is 10^9 bytes; T
is compared with a relative tolerance of 1e-6):

| Vector | Inputs | Expected |
| --- | --- | --- |
| V1 | one policy: rate 108 GB/day, ret 30; available 400 GB | T = 3.703704; effective 3.703704; binds capacity |
| V2 | as V1 with available 1,600 GB | T = 14.814815; binds capacity |
| V3 | A: rate 50 GB/day, ret 7; B: rate 20 GB/day, ret 60; available 1,000 GB | T = 32.5; A effective 7 (time); B effective 32.5 (capacity) |
| V4 | one policy: rate 10 GB/day, ret 30; available 1,000 GB | T infinite; effective 30; binds time |
| V5 | one policy: rate 10 GB/day, ret 30; available 0 (held bytes at low water) | T = 0; effective 0; binds capacity; uploads continue until non-reapable bytes reach object high water |
| V6 | one policy: rate 20 GB/day, ret unlimited; available 500 GB | T = 25; effective 25; binds capacity |

The product exposes, under the `entitlements` purpose:

- `GET /v1/storage/usage?from=<YYYY-MM-DD>`: per consumer, per closed UTC day:
  `retained_bytes_end`, `retained_bytes_max`, `added_bytes`, `deleted_bytes`
  by reason (`object_retention`, `object_capacity`, `operator`), `held_bytes`,
  `non_reapable_bytes` (held archive bytes plus uploads in flight), `object_count`
  (three objects per block, from receipts), `requests` (PUT, GET, HEAD, DELETE
  issued by NVR members and core-elx), `archive_read_bytes`, `rates` (a list of
  `{policy_ref, bytes_per_day, basis}` with opaque policy references and no
  camera names) and `projection` (T, per-policy effective retention and binding
  bound). A day is reported only when closed; a correction is the same day with
  a higher `report_revision`. Bounded pages of at most 31 days. Only `recordings`
  is reported by this change.
- Current-day gauges on web-ng `/metrics` (used bytes, hard limit, T, held
  bytes), so the existing product-metrics scraper can chart them.

The calculated figures and the usage report need nothing from control: on a
self-hosted install with an operator budget they are computed the same way and
shown, and the report route simply has no caller.

### F6. Alerts before reaping, and the reaper event

The C3a checks (`object_capacity_binds`, `object_days_to_high_water`,
`object_used_percent`, `object_overage_active`, `object_held_exceeds`,
`object_archive_paused_capacity`) and the per-pass OCSF reaper event apply
unchanged under an entitlement. `object_overage_active` is meaningful only with
metered overage. Control's own notices and daily digest are control issue
work and are built from the usage report, not from product events.

### F7. SaaS bucket and credential custody

The recordings bucket and its writer, reader and retention keys are created by
control (#182). Their key bytes reach the product's CNPG credential inventory,
never a Kubernetes Secret:

- A new media-purpose route `PUT /v1/media/archive-credentials/:role` (`writer`,
  `reader`, `retention`) carries the key pair and a credential generation. The
  product writes a `network_credential_secrets` row (`s3_compatible`, opaque)
  marked `managed_by = control_plane` with that generation, and points the
  matching slot of `RecordingArchiveSettings` at it. Responses never echo
  secrets; `GET` returns generation and status.
- The destination is registered through the existing
  `POST /v1/media/archive-bindings` with a non-`operator:` provisioning ref.
- Rows with `managed_by = control_plane` and bindings without an `operator:`
  ref are shown but cannot be edited, rotated, disabled or deleted by tenant
  operators; the credential-usage inventory says "Managed by ServiceRadar
  Cloud". This answers the settings change's open question 3 with its default.
- Rotation: control pushes the next generation, the product runs its
  destination test from each NVR member with it and reports the result on GET,
  and the previous generation stays usable until in-flight archive uploads and
  retention deletions that hold it have finished; then control revokes it.
- The provider's keys are `read_only` or `read_write` per bucket, with no
  delete-only key. Role separation rests on the product's grant method
  allowlists (writer PUT/HEAD/GET, reader HEAD/GET, retention DELETE/HEAD,
  `archive_credential_resolver.ex:173-174` plus C3); #182 owns proving the
  isolation.
- The archive reader for playback (D6) uses these CNPG credentials the same way
  as operator destinations: D6's per-request credential mode applies to every
  binding whose credential is in the CNPG inventory, operator-created or
  Cloud-delivered.

**Custody conflict, resolved for the NVR path.** The approved VMS cloud
contract says S3 service credentials use infrastructure custody and Kubernetes
Secret references (`openspec/changes/add-vms-storage-playback-engine/cloud-control-plane.md:144-146`),
and the chart's isolated storage workload takes `mediaStorage.providerSecretName`
(`helm/serviceradar/values.yaml:412-440`). The NVR archive path uses the CNPG
inventory only (`archive_credential_resolver.ex:1-10`). This change decides that
every NVR archive credential (writer, reader, retention), operator-created or
Cloud-delivered, lives in the CNPG inventory, and that no NVR-path component
reads a Kubernetes Secret for bucket credentials. It leaves the isolated
`mediaStorage` workload and the older `ArchiveUploads` path, and the text of
`cloud-control-plane.md`, to `add-vms-storage-playback-engine`: that change
either migrates the workload to the credential broker or records it as the one
infrastructure exception, and amends its own text. Task F.10 files that
amendment request; this change does not edit another change's files.

The warehouse bucket keeps its Kubernetes Secret path: it is ServiceRadar
talking to its own warehouse.

### F8. Lifecycle behaviour in the product

- **Suspension** (control's dunning): control sets the existing durable
  recording stop (`PUT /v1/media/configuration`). New recording admission and
  new archive uploads stop; time retention and capacity reaping keep running
  under the applied policy; holds are kept; entitlement pushes still apply.
  Resume clears the stop; archive backlog uploads oldest first.
- **Termination with holds:** the product never deletes held footage as part of
  deprovisioning, and exposes a bounded, paged hold manifest under the
  `entitlements` purpose (`GET /v1/storage/holds?cursor=`: hold id, interval,
  and per held block the archive object keys, lengths and SHA-256) so control
  can retain exactly the held objects after the deployment is gone. Retention
  and billing of that footage are control's.
- **Export window:** during termination the product keeps playback and holds
  available read-only while the deployment runs; the time-limited bucket key or
  transfer is control's.

### F9. Phases

Ordered as in the findings, calculated figures first:

| Phase | Product work here | Depends on control |
| --- | --- | --- |
| P1 | Calculated retention (F5 formula and vectors), usage figures on the retention tab, self-hosted operator object budget with alerts only (reaper behind a disabled flag) | no |
| P3 | Entitlement routes and `StorageEntitlement` (F1, F2), settings bounds (F3), pending display (F4), usage report and gauges (F5), alerts (F6); advisory: nothing deleted for capacity | yes: entitlement purpose token, push, version gate |
| P4 | Object reaper (C3a) enabled for `reap_oldest`, self-hosted and hosted | yes for hosted: plan terms set `reap_oldest` |
| Parallel | Credential delivery route and read-only Cloud-managed rows (F7) | yes: #182 bucket and keys |
| Later | Suspension and termination behaviour (F8) | yes: control lifecycle workflow |

P2 (pool, allocations, portal split) and P5 (metered overage, ledger, provider
reconciliation) are control-only. The StarRocks warehouse consumer is a
separate product follow-up under the same allocation contract (P6), not part
of this change.

## Risks / Trade-offs

- **One block per request means a handover every block.** Mitigated by
  keyframe cuts and a bounded inbox; any loss is a recorded gap. Multi-block
  requests would reduce handovers but widen the uncertainty of one lost
  response and need range reservation in Core.
- **12 MiB blocks stay short at high bitrate.** Above about 370 kbit/s blocks
  close on bytes, so a 4 Mbit/s stream still makes about 3,433 blocks per day.
  The ledger (A5) absorbs the count; request and row counts only fall with
  blocks above 16 MiB, which wait for multipart (A8).
- **One archive slot per member.** Throughput for many cameras on one member is
  unmeasured; the library allows at most a second client.
- **Archive depends on Core being up.** Accepted for in-cluster placement; edge
  archive during outages needs offline grants.
- **Received-time basis is not capture time.** Labelled everywhere; alignment
  across cameras is approximate by design until the camera-reported basis
  exists.
- **The credential is in web-ng memory for archive reads.** Same model as Core
  holding it for archive writes; alternative in open question 2.
- **Row volume.** Tens of millions of catalog rows per year at fleet scale;
  plain table first, hypertable after benchmarks.
- **The local window can be minutes.** By design when many cameras share a
  volume; the page states the figure and the what-if warns before saving.
- **Ring buffer deletes the only copy in local-only mode.** Only after an
  explicit, audited operator selection; otherwise recording stops when full.
- **No NVR-side autonomous deletion.** A member disconnected from Core keeps
  everything and eventually stops admitting. Chosen over local deletion
  without the hold check.

## Migration Plan

All additions. New tables (`camera_recording_catalog`, `camera_recording_gaps`,
`camera_recording_holds`, `camera_recording_dispositions`,
`camera_recording_access_audit`), new fields on the settings resources, a new
credential role and a receipt version 2 that v1 readers keep accepting. NVR
bounds change behind the existing install values. Blocks recorded before this
change, including those stranded by uncertain captures and rotation, are
adopted, recorded as gaps or raised as unattributable by the reconciler's first
passes (section R). Retention is inert until a policy and settings exist; object retention is
inert until a retention credential is selected; the object reaper is inert until
a budget and `reap_oldest` are recorded or an entitlement supplies them. A
hosted install that has the new release but no entitlement yet holds archive
admission and records locally (F2). Rollback leaves tables unused;
no footage is deleted by a rollback.

## Open Questions

The product owner's decisions of 2026-11-15 are recorded in section 3 and are
no longer open. Remaining questions, each with the default this design follows
until answered:

1. **Archive verification cost.** Keep full readback of every byte, or accept
   provider-verified SHA-256 checksums after qualification to halve provider
   traffic? Default: full readback.
2. **Archive read custody.** Accept web-ng holding the reader credential for
   one request, or route archive reads through a component that resolves its
   own credential at the cost of an extra hop? Default: web-ng resolves.
3. **Who places holds.** New `devices.cameras.recordings.hold` permission,
   admin only by default? Default: yes.
4. **Playback audit granularity.** One record per playlist window, not per
   fragment? Default: per window.
5. **Catalog tombstones.** Keep catalog rows of fully deleted blocks for 90
   days (and at least the CNPG backup horizon), then purge in bounded batches?
   Default: 90 days.
6. **Alert threshold.** Alert when the effective local window falls below
   1 hour with archiving on? Default: 1 hour.
7. **Per-member watermarks and ages.** Is a per-member override needed?
   Default: not in this change; the per-member budget covers the capacity
   difference.
8. **Sharded layout for very large volumes (A5b).** Schedule with this change
   or after multipart (A8)? Default: after A8.
