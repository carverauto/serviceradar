# Design: NVR operator settings

This design covers the operator surface only. Placement, storage modes,
reclamation, archive proofs and playback contracts belong to the
[scalable recording plane](../add-scalable-camera-recording-plane/design.md)
(sections 1, 5, 6 and 9) and the
[VMS storage and playback engine](../add-vms-storage-playback-engine/design.md).
Where this document says "Stage B", the referenced recording-plane task is a
prerequisite, not something this change implements.

## Context

What exists on staging plus the archive slice landing on `feat/nvr-archive-upload`:

| Piece | Where | Reachable by an operator today |
| --- | --- | --- |
| Bounded relay-to-NVR capture | `ServiceRadarCoreElx.CameraRecording.NVRCapture.once_source/4` (up to 300 s, one block) | `eval` only |
| NVR member resolution | `NVRTargetConfig.resolve/2` (mounted config file, no listing function) | no |
| Core block reservation | `ServiceRadar.Camera.RecordingBlock` row per NVR capture: `camera_source_id`, `stream_profile_id`, `storage_id`, `block_key` (= NVR block ID); stays `open_local` because the NVR path never freezes it | no |
| NVR local state | in-process `ServiceRadarNVR.capacity/0`, `list_blocks/0`, `sealed_block/1`, `block_descriptor/1`, `read_block/3`; HTTP exposes only ingest, `/healthz`, `/readyz` | no |
| Archive destination identity | `ServiceRadar.Camera.ArchiveBinding` (immutable, system actor only, v1 fixes `namespace = recordings/v1`, `capability_state = unqualified`) | no |
| Bucket credential | `s3_compatible` native descriptor in `platform.network_credential_secrets`, resolved by `ArchiveCredentialResolver` (`:writer` PUT/HEAD/GET, `:reader` HEAD/GET) | credential CRUD only, at `/settings/networks/credentials` |
| Archive upload (slice) | `NVRArchive.archive_block/5` -> NVR `POST /v1/blocks/<id>/archive`; receipt written only beside the block | `eval` only |
| Recovery gate | `ServiceRadarRecordingControl.RecoveryGate`; every process running `serviceradar_core` (including web-ng) holds `:nvr_recovery_gate` | ConfigMap edit |
| Recordings page | `/cameras/:id/recordings` lists blocks published through `ArchiveUploads` (`archive_published_at`), not NVR blocks | yes, for the older publication path |

## Goals / Non-Goals

Goals: one discoverable Settings view that reports honest state, lets an
operator configure the archive destination and its credential at runtime,
start the recording operations that exist, see where every block lives, and
prove retrieval from each copy.

Non-goals: enabling continuous recording, reclaiming local media, publishing NVR
blocks to the playback catalog, qualifying a provider, opening the recovery gate,
creating chart objects (owned by the separate chart-managed NVR enablement work),
or multitenancy.

## Decisions

### D1. One catalog view with tabs, always listed

Add parent group `:sys_recording` ("Camera Recording", `hero-video-camera`,
order 35) to category `:system` in `ServiceRadarWebNGWeb.Settings.Catalog`,
and one view `:camera_recording` ("Recording & Storage", route
`/settings/recording`, `has_own_stats: true`, permission
`["settings.recording.view", "settings.recording.manage", "settings.recording.operate"]`).
Tabs are `?tab=` sub-entries, each listed in the LiveView's `supported_tabs/0`:
`recorders`, `archive`, `cameras` (Stage A) and `policy`, `health` (Stage B,
rendered as blocked until their prerequisites exist). Keywords: camera, cameras,
nvr, vms, recording, recorder, footage, archive, object storage, s3, bucket,
longshore, retention, hot storage, dual-write, playback.

The view is not gated by a feature flag or capability. When recording is not
installed, the page says so and links the installation docs. Hiding it would
reproduce today's dead end ("camera" finds nothing).

Rationale: the catalog is the single navigation source; one entry puts the page
in the rail, view tree, breadcrumbs and Ctrl+K. A separate top-level "VMS" area
is not justified for one view.

### D2. Three permissions, existing footage permission unchanged

| Key | Grants | Default roles |
| --- | --- | --- |
| `settings.recording.view` | status, destinations, block locations, receipts, operation history | admin |
| `settings.recording.manage` | create destinations, choose the active destination, select credentials, Stage B policy and retention | admin |
| `settings.recording.operate` | bounded capture, archive a block, destination test, retrieval checks | admin |

Selecting a credential additionally requires `settings.credentials.manage`,
because listing credentials is governed by that key today
(`NetworkCredentialSecret` read policy). A user with only
`settings.recording.manage` sees the selected credential's name (via a redacted
projection) and a disabled selector that explains the missing permission.
Stage B playback keeps `devices.cameras.recordings.view` plus camera scope.
The route goes in the existing `:require_authenticated_user` live_session with
the other settings pages. Mount denies a user without any of the three keys,
following `Settings.DataRetentionLive`. Every `handle_event` re-checks the key
for that action with `ServiceRadarWebNG.RBAC.authorize_current/2`, and Core
resources and the core-elx facade re-check against the actor they receive.

### D3. Install topology is deployment-owned; runtime choices are CNPG settings

| Setting | Owner | Why |
| --- | --- | --- |
| NVR replicas, storage IDs, workload mTLS, ingest token | chart / deployment | workload identity and volumes, not operator runtime choices |
| Provider egress CIDRs for NVR pods | chart (`nvr.archive.providerEgress`) | network policy is infrastructure |
| Recovery gate state | deployment control outside GitOps rollback | see D4 |
| `camera_recording_enabled` on core-elx | chart / env | installs the capture supervisor |
| Active destination, credential selection, archive on/off | CNPG `RecordingArchiveSettings` | operator changes at runtime; SaaS renders tenant values |
| Per-camera policy, hot retention window (Stage B) | CNPG, code default 86 400 s | same |

No runtime choice gets a Helm value. A code default applies when no row exists.

### D4. The UI reports the recovery gate and never changes it

The gate must sit outside the CNPG/PVC restore set and application rollback
(`docs/nvr-runtime.md`, "Deployment recovery gate"). A web-ng write path would
put the authority inside the application it guards, so a restored database or
rolled-back release could reopen it. The page shows Core's gate (read locally in
web-ng from `:nvr_recovery_gate`) and each member's gate (from the NVR status
endpoint) separately. It distinguishes "not configured" (nil gate) from "closed"
and links the documented procedure. Opening the gate on a fresh install is
owned by the chart-managed enablement work.

### D5. Destinations are immutable `ArchiveBinding` generations

An operator destination is registered as `ArchiveBinding` with
`provisioning_ref = "operator:<name>"` (`name` matching `[a-z0-9][a-z0-9-]{0,62}`)
and the next `generation` for that ref. Changing any field registers a new
generation and leaves the old one intact. Blocks and receipts keep the binding
they were written under (`RecordingBlock.archive_binding_id` is `on_delete:
:restrict`). There is no edit and no delete. Refs beginning `operator:` are
reserved for this path, so they cannot collide with Cloud-provisioned refs.

The operator asks for a key prefix, but v1 fixes `namespace = "recordings/v1"`.
Add `ArchiveDestination` schema version 2, in which `namespace` carries the
operator prefix: 1..128 bytes of `[a-z0-9/_-]`, no leading or trailing slash, no
empty segment, matching the NVR archive contract's `key_prefix`. It is included
in `destination_sha256`, and the credential grant path
`/<bucket>/<namespace>/*` already follows it. v1 rows remain valid with prefix
`recordings/v1`. The check constraint `camera_archive_binding_v1` becomes a
version-aware constraint. Until v2 ships, the form shows the prefix read-only as
`recordings/v1`.

Registration runs in a Core function
(`ServiceRadar.Camera.ArchiveDestinations.register_operator/2`) that authorizes
`settings.recording.manage` and then calls `ArchiveBinding.register` with the
system actor. Field errors come from `ArchiveDestination.attributes/1`'s rules:
endpoint must be exactly `https://<dns-name>` on port 443 with no IP literal,
region `[a-z0-9-]{1,40}`, bucket a 3..63 character DNS name. The form names the
offending field; it does not report a generic failure.

### D6. Credential selection is a mutable direct reference on a settings singleton

Credential choice is not part of destination identity. Rotating to another
credential record must not change `destination_sha256`, as the `ArchiveBinding`
moduledoc already requires. Add singleton `ServiceRadar.Camera.RecordingArchiveSettings`
(`id = 'deployment'`, AshPaperTrail-audited, listed in
`ServiceRadar.Security.AuditHistory`'s resources), with:

- `active_archive_binding_id` (FK restrict, nullable)
- `writer_credential_secret_id` (FK restrict to `network_credential_secrets`, nullable)
- `reader_credential_secret_id` (FK restrict, nullable; nil means use the writer credential with the `:reader` role)
- `archive_enabled` (default false; Stage A gates the manual archive action, Stage B gates automatic archive)

This is a new direct credential reference, so it carries everything the
credential rule in AGENTS.md requires: a restrictive foreign key, a loader in
`ServiceRadar.Credentials.CredentialUsage.load_direct_consumers/1` (consumer
label "Camera archive (writer)" or "(reader)", linking to
`/settings/recording?tab=archive`), the destroy guard in
`Changes.GuardCredentialDestroy`, and validation that the referenced secret has
provider `s3_compatible`, kind `opaque`, is enabled and is not deleted. The
precedent is the TURN relay settings in `add-webrtc-turn-relay`. The
`s3_compatible` descriptor stays `supports_rules: false`; credential rules are
not used because the consumer's own record defines the scope.

### D7. The NVR performs every provider and media I/O; core-elx orchestrates

web-ng never contacts an NVR or a provider, and media or archive bytes never
transit web-ng or Core. web-ng calls a core-elx facade
(`ServiceRadarCoreElx.CameraRecording.Operations`) through a bounded
`:rpc.call`, using the `Module.concat` node-selection pattern of
`ServiceRadarWebNG.CameraRelayWebRTCSignalingManager`. The facade resolves
members, resolves credentials through `ArchiveCredentialResolver`, and calls NVR
endpoints with the existing pinned mTLS and bearer client.

The destination test and the archive retrieval check run on the NVR member
because the NVR is the uploader. Its egress policy, DNS and TLS trust are what
must work, so a test run from core-elx could pass while uploads fail, or the
reverse. Running there also reuses tonight's Longshore readback code and needs
no new core egress. Stage B archive playback needs a reader that works when the
NVR is gone (recording-plane section 9). That is a separate surface, not a reason
to move Stage A checks.

### D8. Operations run under core-elx supervision with durable records

Capture (up to 300 s) and archive (up to 120 s) outlive a LiveView event. The
facade starts each operation under a core-elx `Task.Supervisor`, independent of
the browser, and records it in append-only `ServiceRadar.Camera.RecordingOperation`:
`kind` (`capture`, `archive`, `destination_test`, `local_check`,
`archive_check`, `receipt_import`), actor ID, target fields, `state`
(`running`, `succeeded`, `failed`, `outcome_unknown`), a bounded error class,
a redacted result summary, `started_at`, `deadline_at` and `finished_at`. One
terminal update is allowed (`running` to a terminal state). A row still
`running` after `deadline_at` reads as `outcome_unknown` through a calculation,
so no reaper is needed and a core-elx restart cannot leave a false "running".
Progress is broadcast on PubSub. The LiveView rebuilds from the table on mount
and handles events only when `connected?/1`.

Uncertain outcomes (`{:nvr_ingest_uncertain, _}`, `:outcome_unknown`, 502
`archive_failed`) are shown as such and never retried automatically, matching
the NVR worker and archive contracts. Concurrency limits follow the NVR:
`archive_busy` is shown as busy, not as failure.

### D9. Core records verified archive copies, append-only

Add `ServiceRadar.Camera.NVRArchiveReceipt`: `storage_id`, `block_key`,
`archive_binding_id` (FK restrict), `destination_sha256`, `recording_block_id`
(nullable FK restrict, set when a Core block row matches), canonical
`receipt_bytes` (at most 8 KiB), `receipt_sha256`, parsed `objects` (name, key,
length, sha256, etag), `verified_at` (from `verified_at_ms`) and `recorded_at`.
Identity `(storage_id, block_key, archive_binding_id)`. Create only: identical
bytes return the existing row, different bytes are refused and the conflict is
logged. No update, no destroy.

Writers:

1. `NVRArchive.archive_block` after a 200, under the binding it sent.
2. `receipt_import`, which pages NVR receipts and records any Core lacks (the
   lost-response case). The receipt's destination must match exactly one binding
   by host, region, bucket and prefix; otherwise it is reported as an unmatched
   receipt and not recorded.

A receipt means "this NVR verified these objects by readback at this time". It
is not archive publication (`ArchiveUploads`), not a qualified archive proof, and
not reclamation authority. Stage B reclamation adds the recording-plane 3.4
proofs on top of it.

### D10. Block location is per copy, and unknown is not absent

Each row in the per-camera list is a Core `RecordingBlock` for that camera whose
`storage_id` belongs to a configured NVR member, newest first, in keyset pages
of 25 rendered with streams. For each page the facade asks the owning member for
the listed IDs (one bounded lookup per member) and joins receipts. The UI
derives:

| Local copy (NVR lookup) | Archive copy (Core receipt) | Shown as |
| --- | --- | --- |
| sealed | none | Local only |
| sealed | receipt | Local + archive |
| absent | receipt | Archive only (in Stage A: "local copy missing", flagged) |
| absent | none | Missing (Core reservation without media) |
| incomplete / unresolved | any | Local unresolved, with the NVR reason |
| member unreachable or lookup refused | any | Local unknown (never "absent") |
| any | receipt, last archive check failed | Archive check failed, with the stage and object |

Core's `open_local` state is shown as "Core reservation" and is not presented as
seal state. The NVR is authoritative for local seal state until local-copy
registration lands.

### D11. Stage A proves retrieval by bytes; Stage B proves it by playback

- Local check: the NVR re-verifies the sealed block (`sealed_block/1`), reads
  every byte through `read_block/3` in its bounded read slots, and returns length
  and SHA-256 for `init.mp4`, `media.m4s` and the canonical descriptor. When a
  receipt exists, Core compares the result to it.
- Archive check: Core sends the receipt's expected objects and a `:reader`
  credential to the NVR. The NVR does HEAD plus ranged GET (at most 4 MiB per
  range, bound to the HEAD ETag), hashes, and returns per-object results. The
  check does not read or need the local copy, so it still works after the local
  block is lost.
- A mismatch, missing object or provider error is reported per object and never
  falls back to the other copy.

Stage B adds forced-source playback through the existing `CameraArchivePlayer`
hook: `source=local` or `source=archive` on the playlist, and when forced, an
unavailable source is an error, not a silent fallback.

### D12. Destination test writes one deterministic probe object

`POST /v1/archive-probe` on each member writes
`<prefix>/_probe/<storage_id>/<credential_secret_id>-<credential_generation>.json`.
The body is deterministic canonical JSON (version, purpose, storage ID,
destination SHA-256), so a repeat run that receives 412 verifies by HEAD and
readback instead of failing. A different existing body is a conflict. The
probe uses the same PUT options as archive (no-clobber, SSE-S3 AES256, SHA-256
checksum), then HEAD and readback. Storage IDs are UUIDs, so `_probe` cannot
collide with block keys. The writer credential has no DELETE, so probes stay
behind: one small object per member per credential generation. The result is
labeled "connectivity test", never "qualified", and `capability_state` stays
`unqualified`.

### D13. Stage B policy is its own resource, not discovery-managed attributes

`Camera.Source` and `Camera.StreamProfile` are written by discovery with the
system actor. Recording intent therefore lives in a separate
`CameraRecordingPolicy` (camera source, stream profile, mode `off|continuous`,
target pool or member, destination or local-only, policy revision) so discovery
cannot overwrite it. A policy edit is a recording-plane assignment transition
(design section 4), not an in-place retarget. The operator's "dual-write" is
shown as "Local + archive". Every sealed block is kept locally and archived after
sealing. It is not a synchronous write to two places.

Hot retention (code default 86 400 s) means "reclaim a local block once it is
older than the window and has a verified archive copy, no hold and no pending
export". A block that has not been archived is never reclaimed by age. In
local-only mode the same field is the archive retention itself, and the UI words
it as permanent deletion.

## Stage A backend surface

What exists versus what must be built, so the implementer can tell UI-only work
from backend work.

### A0. UI-only (no new backend beyond the RBAC catalog keys)

| UI piece | Uses existing |
| --- | --- |
| Catalog parent group, view, route, LiveView, tabs | `Settings.Catalog`, router `live_session` for settings |
| Install and gate banner | web-ng local `RecoveryGate.check/1` on `:nvr_recovery_gate`; `:rpc` to existing `ServiceRadarCoreElx.CameraRecording.Supervisor.enabled?/0` |
| Credential list and "create one" link | `NetworkCredentialSecret.list_by_provider("s3_compatible")` under the user's scope; link to `/settings/networks/credentials` |
| Read-only destination list | `ArchiveBinding` read (system actor after human authorization, as the recordings page does) |
| Camera and relay-eligible profile pickers | `Camera.Source`, `Camera.StreamProfile` reads under scope |
| Links from `/cameras/:id` and `/cameras/:id/recordings` | existing pages |

The RBAC keys (`ServiceRadar.Identity.RBAC.Catalog`) are a one-file Core change
that the catalog validation test requires.

### A1. Core-only backend (`serviceradar_core`, no NVR changes)

| Surface | Kind |
| --- | --- |
| `RecordingArchiveSettings` resource, migration, PaperTrail, AuditHistory allow-list | new resource |
| `NVRArchiveReceipt` resource and migration | new resource |
| `RecordingOperation` resource, migration, `effective_state` calculation | new resource |
| `ArchiveDestinations.register_operator/2` and `ArchiveDestination` schema v2 (`namespace` as key prefix), constraint migration | new function, schema change |
| Credential usage loader, destroy guard and consumer link for the settings references | `CredentialUsage`, `GuardCredentialDestroy` |
| `RecordingBlocks.operator_page/3`: keyset page of a camera's blocks (projection: id, block_key, storage_id, stream_profile_id, state, inserted_at) after `settings.recording.view` | new read |

### A2. After the archive slice merges (touches `serviceradar_nvr`, `serviceradar_nvr_client`, `serviceradar_core_elx/.../camera_recording`)

NVR endpoints (same listener, mTLS and bearer as ingest; JSON bodies at most
8 KiB; read work in the existing read slots and never in recording slots):

| Endpoint | Returns |
| --- | --- |
| `GET /v1/status` | storage_id, gate state and generation, `Capacity.status` measurements (budget, used, free, physical free, reservations), archive slot busy, publication scheduler status, release version |
| `POST /v1/blocks/lookup` (at most 50 IDs) | per ID: `sealed` / `incomplete` / `unresolved` / `absent`, byte length, descriptor SHA-256 when sealed, receipt destination fingerprint when present |
| `GET /v1/blocks?after=<id>&limit=<1..100>` | bounded inventory page, for import and orphan reporting |
| `GET /v1/blocks/<id>/archive-receipt` | stored receipt bytes or 404 |
| `POST /v1/archive-probe` | D12 result, per-stage error like archive |
| `POST /v1/blocks/<id>/verify` | D11 local check |
| `POST /v1/blocks/<id>/archive-verify` | D11 archive check; body carries destination, reader credential and expected objects |

Client functions in `ServiceRadarNVRClient` for each, returning non-200 bodies as
`archive_block/4` does.

core-elx:

| Surface | Notes |
| --- | --- |
| `NVRTargetConfig.members/1` | list member names and storage IDs from the mounted config; no secrets |
| `CameraRecording.Operations` facade | `status/1`, `block_locations/2`, `start_capture/2`, `start_archive/2`, `start_destination_test/2`, `start_local_check/2`, `start_archive_check/2`, `start_receipt_import/1`; each takes the actor, writes `RecordingOperation`, broadcasts progress |
| Receipt persistence in `NVRArchive.archive_block` | write `NVRArchiveReceipt` after 200 |
| Shared readback verifier | move the archive slice's HEAD-plus-ranged-GET hashing into `serviceradar_object_storage` so archive, probe and archive-verify share one implementation |

## Stage B backend surface (blocked)

| Capability | Needs first | New surface |
| --- | --- | --- |
| Continuous recording policy | recording-plane 2.2 (pools, assignment), 2.4 (recording without viewers), 2.5 (handoff) | `CameraRecordingPolicy` resource; assignment transition API; policy tab |
| Automatic archive of every sealed block | 3.2 (continuous sealing, journal/outbox), 3.4 (multipart, recoverable manifests) | NVR archive scheduler driven by the active destination; credential operation grants bounded per recording-plane section 6 |
| Hot retention and reclamation status | 3.4 (receipt-based reclamation), VMS holds/exports, 3.3 for local-only | `hot_retention_seconds` on settings (code default 86 400); NVR reclamation status in `/v1/status` and lookup |
| Backlog and archive health | 3.2, 3.5 (`U <= R`, non-draining backlog) | NVR publishes backlog and goodput to JetStream (`metrics.timeseries.recording.*`), persisted by EventWriter; the health tab reads the telemetry store. Point-in-time values may come from `/v1/status` |
| Forced-source playback | 3.3 (local registration, owner-aware local range service), 3.7 (bounded S3 fragment delivery), catalog publication of NVR archives through the VMS catalog | `source=local\|archive` on the playlist route; reader that works with the NVR absent |

## Risks / Trade-offs

- Two archive paths coexist: `ArchiveUploads` publication (shown on
  `/cameras/:id/recordings`) and NVR receipts (shown on the new page). Both pages
  label their source until Stage B publishes NVR archives through the VMS catalog.
- The destination test is easy to misread as qualification. Mitigation: wording,
  and `capability_state` stays `unqualified`.
- Probe objects accumulate per credential generation. They are bounded and small.
- Long `:rpc` calls: the facade returns an operation ID immediately; only status
  and lookups are synchronous, with deadlines of 5 s or less.
- NVR status endpoints compete with media reads for read slots. Lookup and status
  are metadata-only and bounded; saturation shows "busy", not "absent".
- Requiring `settings.credentials.manage` to change the credential adds friction
  for split-duty roles; it avoids widening credential visibility.

## Migration Plan

New tables and the `ArchiveBinding` constraint change are additive. Existing v1
bindings keep working. No data is backfilled; `receipt_import` records receipts
written before Core persistence existed. Rollback leaves the new tables unused.

## Open Questions

For the product owner unless marked otherwise. Each has a default that this
design follows until answered.

1. **Recovery gate on a fresh install.** May the UI open the gate when no
   retained media exists? Default: no (D4); the chart-managed enablement work
   owns fresh-install opening.
2. **Reader credential.** Is a separate read-only credential required, or is one
   credential per destination enough? Default: optional reader slot, falling
   back to the writer credential with the `:reader` role.
3. **Cloud-provisioned destinations.** On hosted deployments, are bindings
   registered by Cloud read-only in this page? Default: shown read-only; only
   `operator:` refs are created here.
4. **More than one destination per block.** The archive slice writes one
   `archive-receipt.json` per block. Should a block ever be archived to a second
   destination (for example after a destination change)? Default: no in Stage A;
   the NVR refuses a different destination for an already-receipted block.
   (Engineering: confirm the slice returns a conflict rather than overwriting.)
5. **Probe residue.** Is one small probe object per member per credential
   generation under `<prefix>/_probe/` acceptable? The writer credential has no
   delete authority by design.
6. **Hot retention scope.** Is the 24-hour window deployment-wide or per camera,
   and what are its bounds? Default: deployment-wide, 1 hour to 30 days, code
   default 24 hours.
7. **Navigation placement.** System > Camera Recording (default) or Network
   Services?
8. **Who operates.** Admin-only defaults for all three new keys, or should
   operators get `settings.recording.view` and `settings.recording.operate`?
9. **Converging the recordings views.** Confirm Stage B publishes NVR archives
   through the VMS catalog so `/cameras/:id/recordings` becomes the single
   playback surface.
10. **Engineering: key prefix in the archive slice.** The slice passes
    `key_prefix` separately from the binding. Confirm it uses `binding.namespace`
    so v1 blocks land under `recordings/v1/<storage_id>/<block_id>/` and v2 works
    without a contract change.
11. **Engineering: core-elx egress for Stage B archive playback.** A reader
    independent of the NVR needs provider egress from wherever it runs. Is that
    a chart network-policy value for that workload (install topology, so Helm is
    acceptable)?
