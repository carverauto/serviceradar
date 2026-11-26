---
title: Camera Recording & NVR
---

# Camera Recording & NVR

ServiceRadar records camera video streams through `serviceradar-nvr` StatefulSet
members orchestrated by `core-elx`, tracks sealed blocks and retention state in
CNPG, optionally archives sealed blocks to S3-compatible object storage, and
serves unified wall-clock playback and evidence holds from the Web UI.

Operator configuration lives under **Settings -> System -> Camera Recording ->
Recording & Storage** (`/settings/recording`), while historical playback and
evidence holds live on each camera's **Recordings** page
(`/cameras/:camera_source_id/recordings`).

## Architecture and prerequisites

Camera recording separates deployment-owned workload topology from
operator-managed runtime settings:

| Layer | Component | Responsibility |
| --- | --- | --- |
| **Media spool & object I/O** | `serviceradar-nvr` StatefulSet | Owns one replicated PVC and one immutable storage-lifetime UUID (`storage_id`, for example `00000000-0000-4000-8000-000000000011`) per ordinal (`serviceradar-nvr-0`, `serviceradar-nvr-1`). Seals fragmented MP4 (`init.mp4`, `media.m4s`, `descriptor.json`) blocks on disk and uploads or verifies archive objects directly against S3-compatible storage. |
| **Relay & orchestration** | `core-elx` | Hosts the shared camera relay pipeline, acquires recorder ownership fences in CNPG, supervises capture and archive operations, and queries NVR member endpoints over pinned mTLS and bearer tokens. |
| **Control plane & catalog** | CNPG (`serviceradar_core`) | Stores block reservations (`RecordingBlock`), sealed and quarantined catalog entries (`RecordingCatalogEntry`), verified archive receipts (`NVRArchiveReceipt`), gaps (`RecordingGap`), holds (`RecordingHold`), append-only deletion/loss dispositions (`RecordingDisposition`), access audits (`RecordingAccessAudit`), and runtime settings. |
| **Operator UI & playback API** | `web-ng` | Renders `/settings/recording` and `/cameras/:camera_source_id/recordings`, enforces RBAC and camera scope on every request, assembles multi-block HLS v7 VOD playlists, and enforces bounded in-flight read admission. |

### Deployment prerequisites

1. **Enable the NVR workload in Helm (`nvr.enabled: true`) on replicated storage.**
   NVR does not implement application-level media replication; each StatefulSet
   ordinal relies on a qualified replicated CSI storage class (such as Longhorn
   or Ceph RBD) with a retaining PVC lifecycle so local spools and unarchived
   backlogs survive single-node loss.
2. **Verify `core-elx` reachability and NVR client configuration.** `web-ng`
   queries `core-elx` over bounded ERTS RPC to inspect
   `CameraRecording.Supervisor` status and mounted NVR member identities. When
   `core-elx` is unreachable or NVR is not installed, `/settings/recording`
   reports explicit `unknown` or `NVR is not installed` banners rather than
   rendering empty lists.
3. **Satisfy the Deployment Recovery Gate.** Every recording, reconciliation, and
   destructive retention path checks the read-only deployment recovery gate
   (`:nvr_recovery_gate` on Core and the per-member gate on each NVR pod). See
   [NVR runtime and replicated storage: Deployment recovery gate](https://github.com/carverauto/serviceradar/blob/staging/docs/nvr-runtime.md#deployment-recovery-gate)
   for the bootstrap and post-restore gate procedure.

:::important Read-only recovery gate boundary
The Settings UI and HTTP API **report** Core and per-member recovery gate states
(`ready`, `closed`, `not_configured`, or `unknown` with the active generation
prefix), and **never** open, close, or modify the gate. Gate authority stays in
deployment control outside CNPG backups and GitOps rollbacks so a database
restore cannot silently re-open recording or retention against unverified media
volumes.
:::

### Install topology vs CNPG runtime settings

No runtime recording or retention choice uses a Helm value. Install topology
stays in Helm/deployment configuration (`nvr.enabled`, `nvr.replicas`, storage
UUIDs, workload mTLS, `nvr.archive.providerEgress` network policies, and
install capacity bounds `nvr.maxSpoolBytes` / `nvr.reserveBytes`). Operational
choices -- archive destinations, selected `s3_compatible` credentials,
per-camera recording policies, local and object retention rules, and per-member
desired byte budgets -- persist in CNPG with deterministic code defaults when no
row has been saved yet.

---

## Recording & Storage settings (`/settings/recording`)

Open **Settings -> System -> Camera Recording -> Recording & Storage**
(`/settings/recording`), or search the Settings command palette (`Ctrl+K` /
`Cmd+K`) for `camera`, `nvr`, `vms`, `recording`, `archive`, `s3`, `bucket`,
`retention`, or `playback`. Opening the view requires at least one of
`settings.recording.view`, `settings.recording.manage`, or
`settings.recording.operate`.

The top banner displays four live status indicators: **NVR client installation**,
**Core recovery gate**, **`core-elx` reachability**, and **Capture supervisor**,
along with a **Refresh status** action. Below the banner, six tabs organize
day-to-day operations.

### 1. Recorders (`?tab=recorders`)

The **Recorders** tab shows NVR runtime readiness, active storage mode (`Local +
archive` or `Local only: no object storage configured`), and per-member local
byte budgets (`NVRStorageSettings`, `platform.camera_nvr_storage_settings`).

- **Honest unknown states.** If `core-elx` or an NVR member's `GET /v1/status`
  endpoint does not respond within the RPC deadline, member readiness, recovery
  gate state, and live disk measurements render as **`unknown`**, never as an
  empty or absent recorder list.
- **Install defaults from PVC capacity.** By default (`install_default`), Helm
  derives each member's reserve floor as `max(64 MiB, 1% of PVC)`
  (`nvr.reserveBytes`) and its local spool ceiling/default as
  `floor(85% of PVC) - reserve` (`nvr.maxSpoolBytes`). On a `100 GiB` PVC, that
  yields a `1 GiB` reserve and an `84.0 GiB` spool budget, leaving 15% headroom
  for filesystem metadata, journals, and publication records.
- **Per-member desired budget and reserve (`NVRStorageSettings`).** Keyed by the
  member's storage UUID (`storage_id`, for example
  `00000000-0000-4000-8000-000000000011`), administrators with
  `settings.recording.manage` can set `budget_mode` and `reserve_mode` to
  `install_default` or `custom` (`AshPaperTrail`-audited, with monotonic
  `revision`):
  - **Custom budget bounds:** must be at least
    `pinned_bytes + 33,554,432` (`pinned_bytes + 32 MiB`, reserving two `16 MiB`
    block reservations above the member's non-evictable `P1..P5` bytes) and at
    most `1 PiB`, the install ceiling (`nvr.maxSpoolBytes`), and
    `volume_capacity_bytes - effective_reserve_bytes`. Lowering a budget below
    current disk usage (while staying at or above the pinned floor) is permitted:
    it pauses new capture admission until retention eviction brings usage below
    the new high-water mark without triggering immediate NVR-initiated deletes.
  - **Custom reserve bounds:** must be at least `67,108,864` bytes (`64 MiB`)
    and the install reserve floor, and at most `10%` of volume capacity.
- **Desired vs applied tracking.** Each row displays the desired `revision`,
  `sync_state` (`pending`, `applied`, or `refused` with `last_refusal_class`),
  `applied_revision`, `applied_at`, current `pinned_bytes` floor, and projected
  effective local window.

### 2. Archive (`?tab=archive`)

The **Archive** tab manages S3-compatible object storage destinations and binds
reusable credentials on the `RecordingArchiveSettings` singleton
(`platform.camera_recording_archive_settings`).

#### Local-only mode vs S3-compatible archive mode

- **Local-only mode (`Local only: no object storage configured`)** is a complete,
  first-class operating mode when `archive_enabled` is `false` or no active
  destination generation is selected. No S3 bucket or archive credential is
  required, and the UI presents local-only mode as normal state rather than a
  warning.
- **S3-compatible archive mode (`Local + archive`)** copies sealed NVR blocks to
  the active `ArchiveBinding` destination and records readback-verified receipts
  (`NVRArchiveReceipt`). Enabling `archive_enabled` requires an active
  destination generation.
- **Ending or clearing the active destination** while `archive_enabled` remains
  enabled displays an advisory warning: blocks registered while no destination is
  active (and unassigned quarantine copies) wait in `awaiting_binding` (pinned
  locally in `P1`), whereas blocks that already recorded a binding in retained
  history for a non-compromised reason continue archiving under their recorded
  binding.

#### Registering immutable `operator:<name>` destination generations

Archive destinations are immutable `ArchiveBinding` records. Registering a
destination creates `provisioning_ref = "operator:<name>"` at the next monotonic
`generation` using `ArchiveDestination` schema v2:

| Field | Validation rule | Synthetic example |
| --- | --- | --- |
| **Destination name** | `[a-z0-9][a-z0-9-]{0,62}`, persisted as `operator:<name>` | `site-a-archive` (`operator:site-a-archive`) |
| **Endpoint** | `https://<dns-name>` on port `443` (no IP literals) | `https://objects.example.com` |
| **Region** | `[a-z0-9-]{1,40}` | `example-1` |
| **Bucket** | 3..63 character DNS-compatible bucket name | `example-archive` |
| **Key prefix (`namespace`)** | 1..128 bytes of `[a-z0-9/_-]` with no leading, trailing, or empty slash segments (included in `destination_sha256`; v1 bindings retain `recordings/v1`) | `recordings/site-a` |

Existing `ArchiveBinding` generations cannot be edited or deleted
(`on_delete: :restrict` from blocks and receipts). Changing an endpoint, bucket,
region, or prefix registers a new generation while older blocks retain the
binding they were sealed under. Every operator destination displays capability
state `unqualified` -- NVR connectivity probes write and verify a deterministic
`_probe/` object to confirm network reachability, TLS trust, and bucket access,
which does not constitute storage provider qualification.

#### Binding reusable `s3_compatible` credentials

Secret key material is never entered or rendered on `/settings/recording`. Create
credentials first under **Settings -> System -> Security -> Credentials**
(`/settings/networks/credentials`) using `S3-Compatible Object Storage - Access
key` (see [Credential Management](./credentials.md#camera-archive-storage)), then
bind them by reference across three slots:

| Slot | Field | Broker purpose & HTTP verbs | Behavior when unset |
| --- | --- | --- | --- |
| **Writer credential** | `writer_credential_secret_id` | `camera_archive_write` (`PUT`, `HEAD`, `GET` on `/<bucket>/<prefix>/*`) | Archive uploads and destination probes cannot run. |
| **Reader credential** *(optional)* | `reader_credential_secret_id` | `camera_archive_read` (`HEAD`, `GET`) | Defaults to reusing the writer credential scoped down to the read-only `:reader` broker role. |
| **Retention delete credential** *(optional)* | `retention_credential_secret_id` | `camera_archive_retention` (`DELETE`, `HEAD`) | Displays `Object retention not enforced: no delete credential`; expired and capacity-reaped archive objects are **never** deleted until a retention credential is bound. |

Selecting or changing any of the three credential references requires both
`settings.recording.manage` and `settings.credentials.manage`. Administrators
with `settings.recording.manage` alone see the bound credential's redacted name
and a disabled selector explaining the missing permission. Bound credentials are
protected against deletion by `GuardCredentialDestroy` while referenced.

### 3. Cameras (`?tab=cameras`)

The **Cameras** tab inspects per-camera NVR block reservations and cataloged
copy locations in keyset-paginated pages of 25 rows rendered via LiveView
streams (listing camera sources and relay-eligible stream profiles additionally
requires `devices.view`):

- **Core Record (`RecordingBlock` & `RecordingCatalogEntry`):** Distinguishes
  sealed cataloged blocks from uncataloged `open_local` Core reservations and
  surfaces `RecordingBlock.reconciliation_state` (`unresolved`, `adopted`,
  `block_absent`, `unrecoverable_journal`). Core's reservation state is never
  presented as local NVR seal state.
- **Local Copy (NVR):** Shows cataloged `local_state` (`present`, `quarantined`,
  `reclaiming`, `reclaimed`, `missing`), media byte size, and fragment count.
  - **`provisional` badge:** Local copies carry a `provisional` indicator until
    `LocalStorageBinding` registration and current storage qualification exist
    for that `storage_id`.
  - **`unknown` vs `absent`:** When an uncataloged reservation's NVR lookup is
    unreachable or unavailable, the local copy is reported as **`unknown`**,
    never as missing or absent.
- **Archive Copy (Catalog & Receipt):** Shows `archive_state` (`not_required`,
  `awaiting_binding`, `pending`, `failed_retryable`, `failed_terminal`,
  `verified`, `deleting`, `deleted`, `missing`) alongside verified
  `NVRArchiveReceipt` object details (`init.mp4`, `media.m4s`, `descriptor.json`
  keys, byte lengths, SHA-256 digests, ETags, optional receipt v2 `version_id`,
  and `verified_at`).
- **Hold Pin:** Displays active `RecordingHold` pin badges (`archive` or `local`)
  or `No active hold`. Holds are placed and released on the camera Timeline
  page, not in Settings.
- **Timeline Window (Time Basis):** Shows the derived UTC wall-clock window
  tagged with `received` time basis (`uncertainty: unmeasured`) and a
  `time re-anchored` badge when receipt clock drift caused a re-anchor without a
  media gap. Quarantined entries display `Not playable (quarantined)`.

### 4. Policy (`?tab=policy`)

The **Policy** tab configures per-camera, per-profile continuous recording
intent (`CameraRecordingPolicy`, `platform.camera_recording_policies`,
`AshPaperTrail`-audited). Keeping policy in its own resource ensures camera
discovery syncs never overwrite operator recording intent.

Every policy save atomically increments `policy_revision` and acts as a
recording-plane assignment transition: existing blocks retain the `storage_id`
and `archive_binding_id` they were recorded under.

#### Policy fields

- **Camera source & relay-eligible stream profile:** Locked to one policy per
  `(camera_source_id, stream_profile_id)` pair. The form displays each profile's
  codec hint, observed bitrate, estimated daily storage bytes, and estimated
  daily block count (`unknown until recorded` when a profile has never streamed).
- **Recording mode (`mode`):** `off` (default) or `continuous`. In the policies
  table, `continuous` policies show live recorder-claim status
  (`continuous: recording` when an active non-expired recorder claim exists, or
  `continuous: not recording yet` when no recorder is currently running).
- **Assigned NVR member (`nvr_member`):** Target StatefulSet member name (for
  example `serviceradar-nvr-0`), required when `mode` is `continuous`.
- **Storage tier (`storage`):**
  - `local_and_archive` -- seals locally on the NVR spool and queues archive
    upload after sealing (default when deployment archiving is enabled).
  - `local_only` -- seals locally with `archive_state = not_required` (`PD8`).
    Allowed even when deployment archiving is enabled for other cameras; its
    blocks follow the deployment's local-only retention rules.
- **Archive retention override (`archive_retention_override_mode`):** `inherit`
  (uses deployment `archive_retention_days`), `limited` (`1..3,650` days via
  `archive_retention_days_override`), or `unlimited` (no time expiry). For
  example, a camera can record a high-bitrate main stream with a short override
  and a low-bitrate substream with long archive retention.

#### Pre-save What-If capacity and throughput preview

Changing any form input updates the **Pre-Save What-If Capacity & Throughput
Projection (`C1a`)** panel live before saving:

- **Projected local window & `time_to_full`** on the target NVR member, naming
  which bound binds first (`budget`, `max_local_age`, or `block_cap`).
- **Archive throughput (`~2x` capture rate)** needed for upload plus full
  readback verification, compared against trailing measured provider throughput
  and archive goodput.
- **Projected `blocks/day`** against the member's volume block cap (`max_blocks`).
- **Active continuous sessions** on the target member against the session limit
  (`max_sessions`, default `1`..`16` via `SERVICERADAR_NVR_MAX_SESSIONS`).
- **Object effective retention & `days_to_capacity`** across policies.
- **Simulated nominal bitrate (`nominal_bitrate_kbps`, preview-only):** When a
  stream profile has not been measured yet (`unknown until recorded`), entering a
  nominal bitrate in `kbit/s` models local window, block rate, and archive
  throughput impact before saving without persisting the simulated value.

Non-blocking advisory warnings highlight if the projected low-water window drops
below the window alert threshold, sessions exceed `max_sessions`, required
provider throughput exceeds measured throughput, the volume block cap binds
before bytes, or `local_only` is chosen without a confirmed
`local_only_full_policy`.

### 5. Retention (`?tab=retention`)

The **Retention** tab manages deployment-wide local and object-tier retention on
`RecordingArchiveSettings`, displays live CNPG usage and `RetentionCalculator`
projections, provides an interactive What-If rate/spool simulator (`camera_count`,
`nominal_bitrate_kbps` with the `1.02` CMAF packaging factor, and
`local_budget_gib`), and previews eviction consequences before saving. Every
optional limit is stored as an explicit `mode + value` pair enforced by SQL
`CHECK` constraints -- `NULL` never stands in for a hidden default or sentinel
number. The tab remains fully usable when object storage is disabled (`Not used:
local only`).

#### Local tier watermarks and maximum local age ceiling

Local NVR storage acts as a capacity-driven cache rather than a minimum-duration
guarantee:

- **Watermarks:** Space eviction begins when usage reaches
  `local_high_water_percent` (default `90%`, bounds `50..95%` of the member's
  applied budget) and evicts oldest space-evictable blocks first until usage
  reaches `local_low_water_percent` (default `80%`, bounds
  `40..(high_water - 5)%`).
- **Maximum local age ceiling (`max_local_age_mode` + `max_local_age_seconds`):**
  Defaults to `limited` at `86,400` seconds (`24` hours), configurable across
  `3,600..315,360,000` seconds (`1` hour to `10` years) or `unlimited` (`No
  limit`). This is an **upper ceiling** ("keep at most this long locally"), never
  a minimum floor: high-water space eviction can reclaim archive-verified local
  blocks earlier when disk usage requires it.
- **Effective local window alert (`local_window_alert_mode` +
  `local_window_alert_seconds`):** Defaults to `enabled` at `3,600` seconds (`1`
  hour, bounds `60..31,536,000` s) or `disabled`; warns when the low-water
  effective window drops below the threshold.
- **Never evicted automatically:** Unarchived, deleting, or missing-archive
  blocks (`kind (c)`), unreconciled disk blocks (`P2`), local-pinned held blocks
  (`P4`), and quarantined blocks (`row (q)` / `P5`) are never selected by space
  or age eviction.

#### Local-only mode full policy (`local_only_full_policy`)

Blocks recorded with `archive_state = not_required` (`kind (b)` local-only
footage) never reuse `max_local_age_seconds`. Instead, they follow dedicated
local-only settings:

- **`stop_when_full` (default behavior when unset):** Local-only blocks are
  pinned in `P3` and never evicted for space; when the member's spool budget
  fills, new capture admission stops and records a gap.
- **`overwrite_oldest` (confirmed ring buffer):** Evicts the oldest unheld
  local-only blocks from high water down to low water alongside `kind (a)`
  blocks. Because no archive copy exists, saving `overwrite_oldest` requires
  ticking an explicit confirmation checkbox, recording
  `local_only_full_policy_confirmed_by_id` and
  `local_only_full_policy_confirmed_at` in CNPG.
- **Local-only target alert & age ceiling:** `local_only_target_mode` (`target`
  default `604,800` s / `7` days, bounds `3,600..315,360,000` s, or `none`)
  alerts when the ring-buffer window shrinks below target;
  `local_only_max_age_mode` defaults to `unlimited` (`Keep until the volume is
  full`) or `limited` (`3,600..315,360,000` s).

#### Application-managed object retention and object-tier byte budget

ServiceRadar enforces archive expiry and capacity reaping in the application
using the `:retention` (`DELETE`, `HEAD`) credential role so every object
deletion serializes with CNPG catalog locks and evidence holds. Configure bucket
lifecycle rules on the storage provider **only** for aborting incomplete
multipart uploads and expiring `_probe/` connectivity-test objects -- never on
the recorded footage prefix.

- **Object archive retention (`archive_retention_mode` +
  `archive_retention_days`):** Defaults to `limited` at `30` days (bounds
  `1..3,650` days) or `unlimited` (`No limit`). Setting a limited archive
  retention shorter than a limited maximum local age displays a non-blocking
  **Single-copy local tail warning** (archive objects will expire before local
  copies age out).
- **Optional object-tier byte budget (`C3a`):** Set `object_budget_mode` to
  `unlimited` (default) or `limited` (`object_budget_bytes >= 1 GiB` /
  `1,073,741,824` bytes), with `object_high_water_percent` (default `90%`,
  `50..95%`), `object_low_water_percent` (default `80%`, `40..(high - 5)%`), and
  `object_capacity_policy`:
  - `stop_archiving` (default behavior when unset): holds archive upload jobs
    once usage reaches capacity while local NVR recording continues.
  - `reap_oldest`: deletes only the **archive** copies of the oldest unheld
    blocks from high water down to low water, keeping any local copy on disk.
    Requires explicit actor confirmation (`object_capacity_policy_confirmed_by_id`
    and `object_capacity_policy_confirmed_at`) acknowledging that later local
    eviction of reaped blocks removes the last copy. *(On self-hosted Phase 1
    installs, the object budget computes effective retention and raises capacity
    alerts while the background reaper flag remains disabled.)*
- **Same-bucket usage accounting:** Active archive usage (`archive_used_bytes`),
  in-flight uploads, and `non_reapable_bytes` (held archive copies, in-flight
  uploads, `blocked_by_provider` entries, and `_quarantine/` objects) are summed
  across **all retained `ArchiveBinding` generations sharing the active
  `{endpoint, bucket}`**, regardless of key prefix. Bytes retained in other
  buckets are displayed separately and excluded from the active budget.

#### Hold pin rules (`PD5`) and `local_only_after_archive` semantics

- **`PD5` hold pin rule:** An active `RecordingHold` guarantees at least one
  verified copy without letting multi-week investigations exhaust hot NVR disks:
  - When a covered block has `archive_state = verified`, the hold pins the
    **archive** copy (counted in `non_reapable_bytes`), leaving its **local**
    copy evictable by local watermarks and `max_local_age`.
  - In local-only mode, while a block is still unarchived, if the archive copy
    was already deleted before the hold was placed, or if a held archive copy
    becomes `missing`, the hold pins the **local** copy (`P4`). When an
    unarchived held block later reaches `verified`, the pin moves atomically to
    the archive copy.
  - If `non_reapable_bytes` reach object high water, new archive uploads pause
    and raise an alert while local capture continues.
- **`local_only_after_archive`:** When time-based object retention or
  `reap_oldest` deletes an archive copy (`archive_state = deleted`, with
  `archive_deleted_reason` set to `object_retention`, `object_capacity`, or
  `operator`), any remaining local NVR copy becomes **local only after archive
  expiry/reaping** (`kind (a)`). It is **never** counted as unarchived, is
  **never** re-archived automatically (preventing upload loops), and remains
  evictable under local watermarks and `max_local_age`. The Retention tab
  reports total `Local only after archive` bytes and the timestamp of the oldest
  such block.

### 6. Health (`?tab=health`)

The **Health** tab aggregates live CNPG backlog, capacity, reconciliation,
disposition, gap, and alert state across NVR storage members:

1. **Archive Upload Backlog:** Counts and bytes of unarchived catalog entries
   (`awaiting_binding`, `pending`, `failed_retryable`, and `failed_terminal`),
   pinned in `P1`, plus the oldest unarchived block age (`1` hour alarm
   threshold).
2. **Per-Storage Local Capacity & Effective Window:** Per `storage_id`
   (`00000000-0000-4000-8000-000000000011`), shows the calculated effective
   local window (`local storage holds about ...`) and binding bound (`budget`,
   `max_local_age`, or `block_cap`), present local bytes/blocks, disjoint `C1a`
   pinned bytes (`P1` unarchived/deleting/missing + `P2` unreconciled + `P3`
   pinned local-only + `P4` local-pinned holds + `P5` quarantined),
   pinned-growth `time_to_full`, assigned continuous camera count, and live
   disk/ledger status (`unknown until NVR /v1/status reports` until the member
   status endpoint answers).
3. **Core Reservation Resolution Breakdown:** Counts `RecordingBlock` rows by
   `reconciliation_state` (`unresolved`, `adopted`, `block_absent`, and
   `unrecoverable_journal`), plus 24-hour `RecordingDisposition` step and
   failure totals.
4. **Unattributable / Quarantined Blocks (`local_state = quarantined`):** Blocks
   whose journal could not be recovered (`unrecoverable_journal`), that lacked
   Core reservation/PD1 continuation authority (`unattributable`), or whose
   unverified archive binding lacked history or was ended as compromised
   (`binding_without_history`, `binding_compromised`) are isolated in `row (q)`
   (`P5`) and excluded from playback and automatic eviction. Operators with
   `settings.recording.operate` have two audited actions:
   - **Export / Preserve Intent** -- records an audited preservation/export
     operation for inspection.
   - **Audited Delete Intent** -- requires ticking an explicit confirmation
     checkbox (with an optional audit note) to record a permanent
     `operator_quarantine` `RecordingDisposition` delete intent.
5. **Missing Archive Copies (`archive_state = missing`):** Lists catalog entries
   whose archive object was found absent or altered (raising `archive_missing`,
   plus critical `held_archive_missing` if covered by an accepted hold).
   Operators with `settings.recording.operate` can:
   - **Re-archive** *(offered when `local_state` is `present` or `quarantined`)*
     -- queues a transition-8 re-archive under the entry's recorded binding. A
     re-archive never trusts a retained local receipt; it succeeds only when
     local digests match the frozen descriptor (or quarantine receipt), `HEAD`
     confirms the bucket objects are absent, the recorded binding remains in
     non-compromised history, and fresh `PUT` + readback verification pass.
   - **Accept Archive Loss** -- records an audited `archive_loss_accepted`
     disposition (with optional operator note) and transitions `archive_state`
     to `not_required` (leaving `local_state` unchanged, so a quarantined entry
     remains `quarantined`). **When an active hold covers the entry, accepting
     archive loss additionally requires `devices.cameras.recordings.hold`.**
6. **24-Hour Recording Gaps & Active Health Alerts:** Summarizes trailing
   24-hour and open `RecordingGap` rows by reason, alongside deduplicated,
   auto-clearing `TripwireHealth` / `HealthTracker` checks (`storage.recordings.*`
   and `nvr.*`).

---

## Unified timeline playback and holds (`/cameras/:camera_source_id/recordings`)

Opening `/cameras/:camera_source_id/recordings` requires both `devices.view` and
`devices.cameras.recordings.view` plus fresh camera `Source` scope (`devices.cameras.view`
for live video never grants recorded playback). No database queries run during
disconnected LiveView mount, and every LiveView event and HTTP media request
re-verifies active user permissions and camera scope before releasing data.

### Timeline mode vs Published (`ArchiveUploads`) mode

The page header provides a mode toggle between two distinct recording catalogs:

- **Timeline (`?mode=timeline`):** Selected automatically whenever the camera
  has any `RecordingCatalogEntry`, `RecordingGap`, `RecordingHold`, or
  `CameraRecordingPolicy` rows (`RecordingTimeline.has_timeline_data?/2`). Plays
  across consecutive NVR blocks from local NVR storage (through the opt-in NVR
  read listener) and, once an archive reader is installed, from verified
  object-archive copies.
- **Published (`?mode=published`):** Lists single-block recordings published
  through the legacy `ArchiveUploads` workflow
  (`/api/cameras/:camera_source_id/recordings/:id/playlist.m3u8`), labelled
  explicitly so operators never confuse `ArchiveUploads` publication times with
  NVR catalog receipts. When opened without an explicit `mode` parameter and the
  published list is empty and idle, live refresh switches automatically to
  **Timeline** mode once timeline data arrives without interrupting active
  published browsing or playback.

### Coverage bar, time basis, and playback controls

In **Timeline** mode, `/cameras/:camera_source_id/recordings` renders a 3-pane
workspace above the **Detections & Clips** strip:

- **Camera switcher (left rail):** Server-side paginated (`20` cameras per
  page) and searchable (by display name, vendor, vendor camera ID, availability
  status, assigned agent ID, or `site` metadata) RBAC-scoped camera list with
  the active camera pinned at the top and a mobile **Cameras** drawer toggle.
- **Vertical timeline scrubber (middle rail):** Aggregates non-quarantined
  catalog blocks and gaps into bounded buckets (`120` in the UI; up to `1,440`
  buckets across at most `31` days via the API) ordered newest-at-top to
  oldest-at-bottom. Clicking anywhere on the rail (`CameraVerticalTimeline`
  hook) seeks to that wall-clock timestamp and focuses playback around it,
  while dedicated detection and semantic hit markers on the rail remain
  individually clickable. Controls above and below the rail provide a **LIVE**
  link, **Latest** jump, `+`/`-` zoom controls, coverage spans (`15m`, `1h`,
  `6h`, `24h`, `7d`), **Newer** / **Older** window steps, a timezone-aware
  date/time jump form, a collapsible **Gaps** panel (showing per-reason summary
  counts and newest-first gaps paginated at `10` per page), and a collapsible
  **Legend** panel.
- **Main video stage (right pane):** Full-stage 16:9 HLS player
  (`CameraTimelinePlayer`) with stream profile filter, playback source selector
  (`Auto`, `Local`, or `Archive`), **Refresh**, compact transport controls
  (`-10s`, `Play`/`Pause`, `+10s`, elapsed/total time, `Serving:` copy badge,
  `Mute`/`Unmute`, `Fullscreen`, `AI boxes: On/Off`, and `Retry playback`),
  inline semantic clip search, and a **Manage / Holds** slide-over drawer
  trigger showing the recorded hold count.

The vertical coverage rail uses eight states:

| Coverage state | Meaning |
| --- | --- |
| **Local + archived** (`local_and_archived`) | Present on the owning NVR spool and verified in object archive storage. |
| **Archive only** (`archive_only`) | Local copy reclaimed or absent; plays once an archive reader is installed (otherwise shows `Archive playback not available yet`). |
| **Pending archive** (`pending_archive`) | Present locally (`awaiting_binding`, `pending`, `failed_retryable`, `failed_terminal`, `deleting`, or `missing`); playable from the local copy while pinned in `P1`. |
| **Local-only footage** (`local_only`) | Recorded under a `local_only` policy or with archiving disabled (`archive_state = not_required` with no archive binding). |
| **Local only (archive expired/reaped)** (`local_only_after_archive`) | Archive copy was deleted by object retention or capacity reaping while the local NVR copy remains present and evictable under local retention. |
| **Gap** (`gap`) | Recorded `RecordingGap` interval displaying its reason (for example `nvr_refused`, `incomplete_tail`, `block_absent`, `keyframe_wait`, or `quarantined`) and open/closed timestamps. Quarantined entries are never playable and appear as a `quarantined` gap only when both camera and media interval are known. |
| **Not scheduled** (`not_scheduled`) | No continuous recording policy covered the interval. |
| **Deleted by retention** (`deleted_by_retention`) | Local copy reclaimed and archive copy deleted (or `not_required`). |

Above the video stage, badges and banners surface timing and durability provenance:

- **Explicit `received` time basis:** Displays
  `Time basis: received (uncertainty: unmeasured)`. Wall-clock positions are
  based on receipt at `core-elx`. For a bounded capture, the window starts when
  the relay inbox admits the first access unit and spans the sealed descriptor's
  media duration. If the NVR skips leading units while waiting for a keyframe,
  the displayed start precedes the first retained sample by the skipped duration.
- **Clock re-anchor markers (`Clock re-anchored`):** Marks points where receipt
  clock drift triggered a timeline re-anchor without a media gap; individual
  re-anchor timestamps and catalog blocks in the span are listed in the
  **Manage / Holds** slide-over drawer.
- **`provisional` badge:** Indicates local copies on NVR storage lifetimes that
  do not yet have `LocalStorageBinding` registration and current qualification.
- **Live recorder status badge & empty states:** When a `continuous` policy is
  configured, the banner reports **`Recording`** (active non-expired recorder
  claim) or **`Continuous policy set: not recording yet`** (no active recorder
  claim), and the empty state distinguishes a running recorder with no sealed
  blocks yet from a policy with no active recorder. Windows containing only
  verified archive copies (or `Archive` source mode) display
  **`Archive playback not available yet`** until an archive reader is installed.
- **Adjacent-window loading:** Each HLS VOD playlist covers up to `60` minutes
  (`2,048` segments). As playback nears the end of the active window, the
  `CameraTimelinePlayer` hook automatically advances into the adjacent window.
- **Live timeline refresh:** Connected `/cameras/:camera_source_id/recordings`
  sessions subscribe to per-camera `ServiceRadar.Camera.RecordingPubSub`
  updates (`camera:recordings:<camera_source_id>`, coalesced with a `500 ms`
  debounce) alongside a `15 s` periodic fallback tick. Newly sealed blocks
  (`:block_cataloged`), archive copy-state transitions (`:archive_verified`,
  `:archive_failed_terminal`), holds, and event clips appear automatically
  without manual refresh and without interrupting active HLS playback: the
  active playback window (including any user-selected window or clip) and
  current playlist path stay intact while coverage, adjacent-window
  availability, and clips update in place. Transient refresh errors keep active
  playback running and retry on the next tick, while fatal authorization or
  not-found errors tear down live refresh until the view recovers.

### Detections & Clips strip and coverage event markers

In **Timeline** mode, `/cameras/:camera_source_id/recordings` projects a
server-side paginated slice of event clips for the active coverage window and
stream profile via `RecordingEventClips.list_page/3`, listing non-quarantined
playable `RecordingCatalogEntry` blocks as `Recording` segments. Smart and
motion clips need a detection provider, which the ServiceRadar Vantage addon
supplies; without it, only `Recording` segments appear:

- **Coalescing & clip classification:** Adjacent observations of the same
  category within a catalog entry (up to an `8 s` gap) coalesce into one clip:
  - **Smart (`smart`):** `Person`, `Vehicle`, `Animal`, and `Package`
    detections.
  - **Basic (`basic`):** `Motion` (non-suppressed frames with empty detections)
    and `Recording` fallback segments for playable blocks not covered by any
    detection or motion clip. Quarantined entries and their frames are excluded.
- **Vertical timeline event markers:** Coalesced smart and motion clips
  (excluding `Recording` fallbacks) render as color-coded clickable markers
  along the vertical timeline scrubber rail across the full coverage window,
  including clips not currently on the active Detections & Clips page.
- **Server-side mode/category filters & pagination:** The **Detections & Clips**
  strip provides a `Smart` / `Basic` / `All` mode toggle and category filter
  chips (`All`, `Person`, `Vehicle`, `Animal`, `Package`, `Motion`) displaying
  full-window counts. Changing the mode, category, or page reloads a bounded
  page of `12` cards (`2` rows x `6` cards on desktop; up to `48` via
  `RecordingEventClips.list_page/3`) with `Prev` / `Page X / Y` / `Next`
  controls, and a zero-match filter shows a **Reset filters** action. Each card
  displays a lazy-loaded thumbnail when `thumbnail_url` is present (or a
  category-icon placeholder otherwise), relative age, duration, category badge,
  compact timestamp, and storage tier (`local+archive`, `archive`, `local`, or
  `recorded`).
- **Click-to-jump playback:** Selecting a smart or motion clip card (or its
  vertical rail marker) focuses playback on `[start - 5 s, end + 10 s]`
  (clamped to coverage bounds and the `60`-minute playlist limit), seeks to the
  clip's peak timestamp, and highlights matching frame detection overlays when
  available. Selecting a `Recording` fallback segment card focuses playback on
  the segment's exact `[start, end]` window (clamped to coverage bounds and the
  `60`-minute playlist limit) without lead-in/lead-out padding. The selected
  card stays highlighted until playback moves elsewhere (clicking the vertical
  timeline rail to seek, advancing to an adjacent window, jumping to a semantic
  search hit, or changing span/profile outside the clip).

### Timeline HTTP API, copy resolution, and read bounds

All timeline endpoints enforce `X-Content-Type-Options: nosniff` and reject
client-supplied provider URLs or object keys. Coverage, playlist, init,
fragment, and error responses enforce `Cache-Control: private, no-store`, while
successful `200` thumbnail responses return `Cache-Control: private,
max-age=300`. Playlist, init, and fragment endpoints forbid HTTP `Range` headers
(`400 invalid_request`):

| Endpoint | Purpose & limits |
| --- | --- |
| `GET /api/cameras/:camera_source_id/timeline?from=&to=&profile=` | Returns coverage buckets (`1..1,440`), non-quarantined blocks, gaps, holds, and clock re-anchor markers for spans up to `31` days (`416 recording_window_not_satisfiable` if exceeded). |
| `GET /api/cameras/:camera_source_id/timeline/playlist.m3u8?from=&to=&profile=&source=` | Emits an HLS v7 VOD playlist for windows up to `60` minutes and `2,048` segments (`EXT-X-MAP` deduplicated per `init_sha256`, `EXT-X-DISCONTINUITY` across init/epoch/gap boundaries, `EXT-X-PROGRAM-DATE-TIME`), and writes one `RecordingAccessAudit` row. |
| `GET /api/cameras/:camera_source_id/timeline/blocks/:entry_id/init?source=` | Serves verified CMAF initialization bytes (`<= 1 MiB`) with `Content-Type: video/mp4` and `X-Recording-Copy`. |
| `GET /api/cameras/:camera_source_id/timeline/blocks/:entry_id/fragments/:index?source=` | Serves verified fragment `0..4095` (`<= 4 MiB`) with `Content-Type: video/mp4` and `X-Recording-Copy`. |
| `GET /api/cameras/:camera_source_id/timeline/thumbnails/:kind/:id.jpg` | Serves a bounded JPEG clip thumbnail (`<= 64 KiB`, `Content-Type: image/jpeg`, `Cache-Control: private, max-age=300`) for a playable non-quarantined `block` (`RecordingCatalogEntry`) scoped to `:camera_source_id` (`:id` accepts `<uuid>` or `<uuid>.jpg`). Returns `400 invalid_request` on invalid kind/UUID and `404 thumbnail_not_found` when absent, cross-camera, quarantined, or purged on terminal retention deletion. |

#### Source modes, SHA-256 verification, and `X-Recording-Copy`

- **`source=auto` (default):** Attempts a `present` local NVR copy first (`2 s`
  timeout) via `CameraTimelineReader.NVRLocal` (configured by
  `SERVICERADAR_NVR_READ_CLIENT_CONFIG_FILE` and
  `SERVICERADAR_NVR_READ_CLIENT_TOKEN_FILE`, or Helm `nvr.read.enabled`). When
  an archive reader is installed (`CameraTimelineReader.Archive`, configured by
  `SERVICERADAR_TIMELINE_ARCHIVE_READER_CONFIG` or Helm `archiveReader.enabled:
  true` with `archiveReader.mode: perRequest`; see
  [Separate archive reader installation](https://github.com/carverauto/serviceradar/blob/staging/docs/archive-init-storage.md#separate-archive-reader-installation)),
  falls back automatically to a `verified` archive copy on timeout,
  unavailability, or not-found. Until an archive reader is installed, the
  Timeline UI requests `source=local` in `Auto` mode; direct API requests for
  archive-only entries return `409 archive_playback_not_available`, while a
  local read failure on an entry with an archive copy returns the local error
  (`409 recording_unavailable` on not-found, `409 recording_integrity_failed`
  on mismatch, `503 recording_read_unavailable` on reader unavailability).
- **`source=local` / `source=archive` (forced source):** Reads **only** the
  requested copy and never falls back (`409 recording_unavailable` when absent,
  or `409 archive_playback_not_available` for `source=archive` when no archive
  reader is installed).
- **Cryptographic digest verification:** Before releasing any init or fragment
  bytes, `CameraTimelineReader` verifies exact byte length and lowercase SHA-256
  against the block's frozen descriptor, and `CameraTimelineController`
  re-checks user permissions and camera scope. If a local read fails SHA-256 or
  length verification, the corrupt bytes are discarded, the catalog entry's
  local copy is marked `missing` (`local_integrity`), and `auto` mode falls back
  only if a `verified` archive copy exists (otherwise returning `409
  recording_integrity_failed`).
- **`X-Recording-Copy` response header:** Every `200` init/fragment response
  includes `X-Recording-Copy: local`, `X-Recording-Copy: local; provisional`, or
  `X-Recording-Copy: archive`, updating the player's live `Serving:` indicator.
- **Bounded in-flight read admission (`CameraTimelineAdmission`):** Enforces
  non-queuing ETS counters of at most **`4` concurrent init/fragment reads per
  playback session** (`{user_id, camera_source_id}`) and **`64` concurrent reads
  per `web-ng` node**. Excess requests return `503 Service Unavailable` with
  `Retry-After: 1` and `{"error": "playback_capacity_exhausted"}`.

### Append-only access audit (`RecordingAccessAudit`)

Every issued playlist window and every hold placement or release appends an
immutable row to `platform.camera_recording_access_audits` (`event_kind` in
`playlist_window`, `hold_placed`, `hold_released`), recording the actor ID,
camera, stream profile, `[window_start_us, window_end_us)`, `source_mode`,
`time_basis`, segment count, and metadata. Database triggers refuse `UPDATE` and
`DELETE` on audit rows. Individual fragment fetches are covered by their issued
playlist window rather than writing per-fragment rows.

### Placing and releasing investigation and export holds

Users with `devices.cameras.recordings.hold` (along with `devices.view` and
`devices.cameras.recordings.view`) can place and release holds in the
**Manage / Holds** slide-over drawer (**Manage Holds & Catalog**) on
`/cameras/:camera_source_id/recordings`:

1. Click **Manage / Holds** below the video player to open the slide-over
   drawer. The **Start** and **End** date/time inputs (in your user timezone)
   are pre-filled from the active playback window; you can also choose a quick
   preset (`Current window`, `Last 15m`, `Last 1h`, `Last 24h`) or enter
   explicit bounds.
2. Choose **Hold kind** (`Investigation` or `Export`), enter a required ticket
   or incident **Reason**, and click **Place hold**.
3. `RecordingHolds.place_hold/2` locks intersecting non-quarantined
   `RecordingCatalogEntry` rows (`SELECT ... FOR UPDATE` in primary-key order)
   in one transaction with `RecordingHold` and `RecordingAccessAudit`, applying
   the `PD5` pin rule (`Pinned: archive` when verified, otherwise `Pinned:
   local`). Any block that already had an in-progress deletion with no surviving
   pinnable copy is recorded in `unavailable_blocks` (`unavailable, deletion in
   progress`) and flagged on the hold card.
4. Holds never expire automatically on disconnect, policy edits, or disk
   pressure. To release a hold, enter an optional release note on the accepted
   hold card and click **Release**.

---

## RBAC permissions summary

All camera recording and settings permissions default to `admin` (except
`devices.view`, which defaults to all built-in roles) and can be delegated
through custom role profiles (see [Roles & Permissions](./rbac-and-roles.md)):

| Permission | Default roles | What it authorizes |
| --- | --- | --- |
| `devices.view` | `viewer`, `helpdesk`, `operator`, `admin` | Required alongside camera permissions to resolve camera inventory, list camera sources and stream profiles in Settings, and open `/cameras/:camera_source_id/recordings`. |
| `devices.cameras.recordings.view` | `admin` | Open `/cameras/:camera_source_id/recordings` (Timeline and Published modes), query timeline coverage, issue HLS VOD playlists, fetch clip thumbnails, and stream verified init/fragment bytes (`auto`, `local`, or `archive`). |
| `devices.cameras.recordings.hold` | `admin` | Place and release `investigation` or `export` holds on the camera Timeline, and authorize **Accept Archive Loss** on `/settings/recording?tab=health` when an entry is covered by an active hold. |
| `settings.recording.view` | `admin` | Open `/settings/recording` and inspect recorder status, desired/applied storage budgets, archive bindings, redacted credential names, block locations, policies, retention projections, and health summaries. |
| `settings.recording.manage` | `admin` | Register immutable `operator:<name>` archive destinations, choose the active destination, toggle `archive_enabled`, save per-camera `CameraRecordingPolicy` rows, save deployment `retention` settings, and save per-member `NVRStorageSettings` budgets and reserves. |
| `settings.credentials.manage` | `admin` | Required *in addition to* `settings.recording.manage` to list and change the writer, reader, or retention `s3_compatible` credentials on `/settings/recording?tab=archive`. |
| `settings.recording.operate` | `admin` | Run supervised recorder operations (bounded captures, manual archive uploads, connectivity probes, retrieval checks) and execute audited **Health** tab actions (quarantine export/preserve intent, confirmed quarantine delete intent, missing-archive re-archive, and unheld missing-archive loss acceptance). |

---

## Operational note: immediate control-plane enforcement vs runtime workers

When operating `/settings/recording` and `/cameras/:camera_source_id/recordings`,
distinguish between control-plane state enforced immediately in CNPG/`web-ng`
and background runtime workers in `core-elx` and `serviceradar-nvr`:

- **Enforced immediately in CNPG and `web-ng` today:**
  - All RBAC checks, split-duty credential authorization, `GuardCredentialDestroy`
    protection across writer/reader/retention slots, and immutable
    `ArchiveBinding` v2 destination registration.
  - Auditing and SQL constraints on `CameraRecordingPolicy`,
    `NVRStorageSettings` (`pinned_bytes + 32 MiB` floor), and
    `RecordingArchiveSettings` (watermarks, age ceilings, confirmed
    `local_only_full_policy`, and confirmed `object_capacity_policy`), plus live
    `RetentionCalculator` usage and What-If projections.
  - Historical block freeze (`freeze_historical/3`), `PD1` rotated-block
    adoption, reservation resolution tracking, transactional `RecordingHold`
    placement/release (`PD5`), append-only `RecordingDisposition` and
    `RecordingAccessAudit` triggers, and audited quarantine / missing-archive
    operator intents.
  - Unified Timeline UI, coverage bucketing, multi-block HLS v7 VOD playlist
    generation, forced-source routing (`auto`, `local`, `archive`), SHA-256
    digest verification, `X-Recording-Copy` headers, and 4-per-session /
    64-per-node read admission.
- **Requires active `core-elx` and `serviceradar-nvr` runtime workers:**
  - **Continuous capture & auto-archive:** Saving a `continuous` policy persists
    the assignment in CNPG immediately; unattended continuous capture and
    background upload retries execute through `ContinuousRecorder` and
    `ArchiveBlockJob` on `core-elx`.
  - **Volume reconciliation & live member sync:** A sealed block whose live
    registration failed can still appear as an open reservation. Automatic
    inventory reconciliation and desired budget pushes are pending. See the
    [reconciliation and storage sync tasks](https://github.com/carverauto/serviceradar/blob/staging/openspec/changes/add-nvr-retention-and-timeline-playback/tasks.md).
  - **Background eviction & byte-range media readers:** Automatic local disk
    reclamation runs every 60 seconds per configured NVR member through
    `LocalRetentionJob` on `core-elx`'s `maintenance` Oban queue (enforcing the
    `C1` watermarks and age ceilings with `PD5` hold checks, NVR
    `POST /v1/blocks/<id>/reclaim`, and lookup verification, capped at 500
    blocks per pass while the deployment recovery gate and member inventory are
    ready). Expired object deletion (`ArchiveRetentionJob`) and self-hosted
    capacity reaping (gated behind the disabled Phase 1 reaper flag) remain
    pending background jobs; when local reclamation cannot run (for example
    while the recovery gate is closed or `local_only_full_policy` is
    `stop_when_full`), NVR spools retain sealed blocks and refuse new capture
    admission once spool budget is reached. Local timeline
    init/fragment playback uses the opt-in NVR read listener (`nvr.read.enabled`
    in Helm) and `CameraTimelineReader.NVRLocal` (returning `503
    recording_read_unavailable` when the read client is unconfigured or
    unreachable); archive-only playback and local-to-archive fallback use the
    opt-in per-request isolated archive reader (`archiveReader.enabled: true`
    with `archiveReader.mode: perRequest` in Helm, wiring
    `SERVICERADAR_TIMELINE_ARCHIVE_READER_CONFIG` and
    `CameraTimelineReader.Archive`), returning `409
    archive_playback_not_available` when no archive reader is installed.

## Related pages

- [Credential Management: Camera archive storage](./credentials.md#camera-archive-storage)
- [Roles & Permissions: Camera recording and storage settings](./rbac-and-roles.md#camera-recording-and-storage-settings)
- [Object Store Retention (NATS JetStream internal artifacts)](./object-store-retention.md)
- [NVR runtime and replicated storage](https://github.com/carverauto/serviceradar/blob/staging/docs/nvr-runtime.md)
