# Tasks: NVR continuous recording, retention and unified timeline playback

Stages ship independently in the order of their dependencies, not their
letters. Section references point to [design.md](design.md).

## Dependencies

| Stage | Depends on | Unblocks |
| --- | --- | --- |
| B. Catalog | `add-nvr-operator-settings` Stage A (`NVRArchiveReceipt`, `RecordingArchiveSettings`, `POST /v1/blocks/lookup`, `GET /v1/status`) | R, A.3-A.5, C, D, F |
| R. Reconciliation (no stranded footage) | B; A.4 archive job (R.6 can ship with B.3 and enqueue later); the settings change's inventory page endpoint | C (retention may not ship before R); continuous recording (A) in production |
| A.1 NVR limits and ledger | nothing (the block sizing is already merged in #6660) | A.2 |
| A.2-A.5 Continuous recording and auto archive | A.1, B, R | C, the settings change's Stage B policy and health tabs |
| C1-C8 Local tier, local-only, object retention, holds, alerts | B, R; A.4 for archive-gated eviction; current-history reconciliation for destructive operations on a member | E retention fields, C3a |
| C9 Runtime budget and reserve | nothing for C.13-C.15 (NVR and Core resource in parallel); C.16-C.17 after both | the per-member budget being editable; until then the chart-derived budget is shown read-only |
| C3a Object-tier capacity | B, C.1 (retention credential), C.3 (dispositions), C.2 (hold pins) | F.3-F.4 (hosted reaper) |
| D. Playback | B (works on bounded captures before A ships); D.1 and D.2 can start earlier | D.5 UI |
| E. Settings | the settings change's `/settings/recording` view; each field lands with the stage that uses it | |
| F.1-F.2 (P1) Calculated retention and usage figures | B, C3a usage figure; nothing from control | F.3 |
| F.3-F.6 (P3) Entitlement routes, settings bounds, pending changes, usage report | F.1; control issue: `entitlements` purpose token, push, chart-version gate | F.7 |
| F.7 (P4) Reaper under an entitlement | C3a reaper, F.3; control: plan terms set `reap_oldest` | |
| F.8 Credential delivery (parallel) | C.1; control #182: recordings bucket and keys | SaaS recording at all |
| F.9 Lifecycle | F.3, C.2; control lifecycle workflow | |

Work that can run in parallel from day one, each in a different component:
A.1 (NVR limits and ledger), B.1-B.2 (Core catalog and gap resources), C.1 and
C.2 (retention credential role, hold resource), C.13-C.15 (runtime budget:
Core resource, NVR route, client), D.1 (NVR read listener), D.2 (archive reader
per-request credential mode), R.4-R.5 (NVR inventory state and remote
recovery), F.1 (the shared retention calculator with its test vectors, which
is pure code). R.1-R.2 start as soon as B.1 and B.3 exist; C3a and F.2 start
once B and C.1-C.3 exist; F.3 onward waits for the control issue's token and
gate.

## B. Core catalog of NVR blocks (design B)

### serviceradar_core
- [ ] B.1 `RecordingCatalogEntry` resource, migration and indexes (design B3); create-only registration identity on `(storage_id, block_key)`; database trigger refusing transitions out of `reclaimed` and `deleted`.
- [ ] B.2 `RecordingGap` resource and migration (append-only except closing `end_us`).
- [ ] B.3 `RecordingBlocks.freeze_and_catalog/6`: freeze plus catalog insert in one transaction under `RecorderOwnership.with_current`; exact retry returns the entry; conflicting descriptor refused.
- [ ] B.4 `RecordingBlocks.acquire_upload/4` refuses blocks stored on an NVR `LocalStorageBinding`.

### serviceradar_nvr and serviceradar_nvr_client
- [ ] B.5 `GET /v1/blocks/<id>/descriptor` returning canonical descriptor bytes from the existing read pool; client function.

### serviceradar_core_elx
- [ ] B.6 `NVRWorker` registers its block through B.3 before releasing its claim; a block it cannot register is left to the reconciler (R).
- [ ] B.7 Time basis observation: inbox stamps admission UTC per access unit; worker records first-unit PTS and receipt time (design T).

### web-ng
- [ ] B.8 Settings `cameras` tab block list reads catalog state (copy states, time basis) alongside the settings change's lookup join.

### Verification
- [ ] B.9 Tests through the real freeze path: exact retry, conflicting descriptor, block with no Core authority not cataloged, terminal-state trigger refuses revival. Follow the test-audit skill; tests delete the rows they create.

## R. Reconciliation: no stranded footage (design R)

### serviceradar_core
- [ ] R.1 `RecordingBlocks.freeze_historical/3` (system actor, reconciler only): every live-freeze check except claim liveness, replaced by writer retirement; same row lock as the live freeze; catalog insert in the same transaction (design R3).
- [ ] R.2 Rotated-block adoption: create the missing `RecordingBlock` row from the reserved predecessor when the capture identity is unallocated, advance the claim's `next_block_sequence` when it is the same epoch, then R.1 (design R3).
- [ ] R.3 Reservation resolution state on `RecordingBlock` (or a side table) so a reservation resolved as adopted, `block_absent` or `unrecoverable_journal` is not re-examined; `RecordingOrphan` record for unattributable blocks with evidence and operator disposition.

### serviceradar_nvr and serviceradar_nvr_client
- [ ] R.4 Inventory page reports block state (`sealed`, `incomplete`, `tombstoned`) and descriptor digest for sealed blocks (extends the settings change's `GET /v1/blocks` page); client function.
- [ ] R.5 `recover_block/2` over the private listener, refusing only when an active session or publication touches that block or its source and profile (today it refuses whenever any recording is active, `capacity.ex:133-136`); client function.

### serviceradar_core_elx
- [ ] R.6 `NVRReconcileJob` per member (every 5 minutes and after each uncertain capture): page inventory, classify each block (design R4 steps 1-6), adopt, recover, record gaps, enqueue archive only for blocks that archive (archiving enabled and policy `local_and_archive`; otherwise `not_required`) and for every pending or retryable entry without a job that still archives, moving one that no longer archives to `not_required`.
- [ ] R.7 Residue disposal for `unrecoverable_journal` after the 7-day grace, unless held, through `RecordingDisposition` and the NVR reclaim endpoint (C.6).
- [ ] R.8 Alarms through `TripwireHealth.record/4` (design R5, C8): oldest unarchived over 1 hour, any `failed_terminal`, any unattributable block, block unreconciled past its bound, reconciliation paused over 1 hour.
- [ ] R.9 Backlog figures (unarchived count, bytes, oldest unarchived age, unreconciled and unattributable counts) published through the settings change's JetStream backlog telemetry.

### web-ng
- [ ] R.10 Settings `health` tab: the R.9 figures and alarms per member; unattributable list with operator actions (audited delete, export), gated by `settings.recording.operate`.

### Verification
- [ ] R.11 Synthetic cases through the real NVR and Core paths: uncertain capture later reconciled; rotated second block adopted; mismatched identity or clock epoch stays unattributable; concurrent live and historical freeze yield one entry; archive outage then catch-up with no reclaim before verification; incomplete journal recovered with an `incomplete_tail` gap; unrecoverable journal becomes a gap and is disposed after grace; reconciliation pauses while history is unresolved.

## A. Continuous recording that fits the volume (design A)

### A.1 serviceradar_nvr and serviceradar_recording (parallel with B)
- [x] A.1.1 Block sizing baseline, merged in #6660: `SERVICERADAR_NVR_MAX_BLOCK_FRAGMENTS` (default 150, range 8 to 256), 16 MiB block limit and 2 s minimum fragment unchanged, Core capture ceilings 270 s / 8,100 frames / 12 MiB, chart NVR session limit 300 s. This removed the two-block capture hazard (design 1.2); Stage A builds on it without changing it.
- [ ] A.1.2 Incremental inventory ledger in `Capacity` with paged boot rebuild (`:nvr_inventory_rebuilding`), bounded rotating audit (`:nvr_inventory_mismatch` closes admission) and `SERVICERADAR_NVR_MAX_BLOCKS` (default 131,072, ceiling 262,144).
- [ ] A.1.3 Release tests: full-cap refusal leaves reads, archive and receipts working; ledger rebuild after restart; audit mismatch closes admission without touching files; a request never rotates inside the coordinator's bounds.

### A.2 serviceradar_core
- [ ] A.2.1 `CameraRecordingPolicy` fields from design E1 (resource named by the settings change), PaperTrail audited; policy edits are assignment transitions.

### A.3 serviceradar_core_elx
- [ ] A.3.1 `ContinuousRecorder` under the recording supervisor: relay open with recorder consumer lease, one claim per run, one inbox per run, block loop with soft and hard bounds (design A2, A3).
- [ ] A.3.2 Keyframe-aligned handover with bounded inbox; exact gap accounting by relay sequence and PTS; gap rows with reasons (design A4, A7).
- [ ] A.3.3 Uncertain outcome handling by lookup under the live claim (design A3 table).
- [ ] A.3.4 Continuous path uses the A.1.1 ceilings as hard bounds with soft targets 260 s / 7,800 frames / 10 MiB for keyframe cuts (design A4).
- [ ] A.3.5 Drift check and re-anchoring (design T).

### A.4 serviceradar_core_elx archive scheduler
- [ ] A.4.1 `ArchiveBlockJob` (Oban, unique per entry, queue `nvr_archive`): state guard, receipt recording and catalog transition in one transaction, busy snooze, backoff, terminal classes (design A6).
- [ ] A.4.2 Backlog numbers from catalog and jobs for the settings change's backlog telemetry (JetStream, EventWriter).

### A.5 helm and docs
- [ ] A.5.1 Chart: NVR session count sized to the member's assigned cameras; `SERVICERADAR_NVR_MAX_BLOCKS` value; archive memory guidance unchanged (one slot, 16 MiB block, 48 MiB locked).
- [ ] A.5.2 Docs: `docs/nvr-ingest.md` and `docs/nvr-runtime.md` updated for block bounds, continuous runs, ledger and cap behavior.

### A.7 Later: larger blocks and very large volumes (design A5, A8)
- [ ] A.7.1 BLOCKED on Longshore multipart (task 2.2) and its provider qualification (recording-plane 3.4): multipart archive of `media.m4s` in parts of at most 16 MiB, then raise the NVR block byte limit and Core byte ceiling so blocks close on time (about 300 s) at any bitrate.
- [ ] A.7.3 LATER (A5b): sharded block directory layout for newly installed volumes, recorded in bootstrap evidence; aggregate per-shard ledger with per-block entries only for blocks with missing publication allowances; streamed boot rebuild; block cap default derived from the budget (budget / 4 MiB, 4,096 to 16,777,216). Needed before one volume keeps more than about 262,144 blocks.
- [ ] A.7.2 Archive slot count beyond one per member (the library maximum is two live clients per VM, including draining ones), after throughput measurement.

### Verification
- [ ] A.6 Synthetic continuous run across several blocks: contiguous handovers, forced overflow produces an exact gap, NVR refusal produces a gap, archive retries until verified. Real camera acceptance only after synthetic success and explicit approval.

## C. Retention and reclaim (design C)

### serviceradar_core (C.1-C.2 parallel with B)
- [ ] C.1 `ArchiveCredentialResolver` role `:retention` (DELETE, HEAD); `retention_credential_secret_id` on `RecordingArchiveSettings` with credential-usage loader, destroy guard and validation.
- [ ] C.2 `RecordingHold` resource and migration, permission `devices.cameras.recordings.hold`, acceptance serialized with deletion intents on covered entries; pinned-copy rule (archive copy when verified, else local; pin moves on verification and back on a failed re-check, design C4); daily bounded HEAD re-check of held archive copies.
- [ ] C.3 `RecordingDisposition` append-only resource and migration.
- [ ] C.4 Retention fields on `RecordingArchiveSettings` per design E1: watermarks; mode-plus-value pairs for maximum local age, window alert, local-only target, local-only maximum age and archive retention, each with a check constraint that the value is present and in bounds exactly when the mode needs it; `local_only_full_policy` with confirming actor and time; the per-policy archive retention override; a warning, not a refusal, when a limited archive retention is shorter than a limited maximum local age; `archive_deleted_reason` on the catalog entry (design B3).
- [ ] C.5 Receipt version 2 with per-object version ID; v1 still accepted.

### serviceradar_nvr and serviceradar_nvr_client
- [ ] C.6 `POST /v1/blocks/<id>/reclaim` bound to an operation ID and expected descriptor SHA-256: fsynced tombstone in a disposition journal, then unlink; boot completes tombstoned removals; lookup reports `reclaimed`; inventory and ledger accept the journal entry.

### serviceradar_core_elx
- [ ] C.7 Local retention job per member, every 60 s from `GET /v1/status`: the C1 eviction table by archive state: space eviction from high to low water over kind (a) and, under `overwrite_oldest`, kind (b) in one oldest-first order; age eviction of kind (a) by `max_local_age` and of kind (b) by `local_only_max_age` whatever the full policy; kind (c) never; only cataloged, reconciled blocks whose local copy is not a hold's pinned copy; hold check and disposition intent in one transaction; NVR reclaim; lookup re-check; at most 500 blocks per pass.
- [ ] C.8 `ArchiveRetentionJob`: HEAD match, versioned delete, HEAD 404 re-check, object-changed and provider-lock handling (design C3); deletes only the archive copy and records a present local copy as local only after archive expiry. Uses `ServiceRadar.HTTP.EgressClient` and the existing signer.
- [ ] C.9 Per-kind rates (15-minute and 6-hour byte sums divided by their window lengths), pinned bytes per C1a, the common-cutoff solve for the per-kind window (C1a, as in C3a), and time-to-full from pinned growth (C5), per member from catalog and status; what-if projection function used by the policy tab.
- [ ] C.9a Storage health checks through `TripwireHealth.record/4`, raised and cleared each pass (design C8).
- [ ] C.10 Daily retention audit sample (design C6).

### helm and docs
- [ ] C.11 Provider egress NetworkPolicy for core-elx (install value); docs: retention credential, why provider lifecycle is limited to incomplete uploads and probe residue.
- [ ] C.11a Chart: derive `nvr.reserveBytes` (max(64 MiB, 1% of `nvr.storage.size`)) and `nvr.maxSpoolBytes` (85% of the size minus the reserve) when unset, using `serviceradar.quantityBytes`; refuse an explicit budget plus reserve larger than the volume; helm unittest cases for 20 GiB and 100 GiB.

### serviceradar_nvr (budget ceiling)
- [ ] C.11b Raise the `SERVICERADAR_NVR_MAX_SPOOL_BYTES` ceiling from 1 TiB to 1 PiB (`config.ex:22`; decided, design C1); report effective budget in `GET /v1/status`.

### C9. Runtime budget and reserve (design C9)
- [ ] C.13 serviceradar_core: `NVRStorageSettings` resource and migration keyed by storage UUID (budget and reserve mode-plus-value, monotonic revision, PaperTrail); save-time bounds against install values, volume capacity and pinned bytes from the catalog (unarchived, unreconciled, held local copies that are the pinned copy, and local-only footage unless `overwrite_oldest` is recorded).
- [ ] C.14 serviceradar_nvr: `PUT /v1/storage/settings` on the pinned listener (canonical JSON at most 1 KiB, storage UUID and recovery generation check, revision ordering, bounds against install values and a fresh volume measurement); persist `.storage-settings.json` beside `.storage-id` (temp, fsync, rename, directory fsync) charged to the control reserve; inventory accepts the root entry; `Capacity` applies it atomically; boot loads or refuses it; `GET /v1/status` reports applied values, revision, install ceiling and floor, volume capacity and settings state.
- [ ] C.15 serviceradar_nvr_client: settings push function.
- [ ] C.16 serviceradar_core_elx: `NVRStorageSettingsSyncJob` pushing desired revisions, retrying, recording refusals; health check for pending over 10 minutes or refused.
- [ ] C.17 web-ng: `recorders` tab per-member budget and reserve with desired versus applied; read-only install values until C.13-C.16 land.
- [ ] C.18 Tests: revision ordering and idempotent retry; bounds refusals; lowering below usage stops admission without deleting; budget below pinned bytes refused by Core; persisted setting survives restart; lowered install ceiling refuses a persisted budget at boot.

### Object-tier capacity (design C3a)
- [ ] C.19 serviceradar_core: object budget, watermarks and `object_capacity_policy` (with confirming actor and time, or the entitlement revision; the recorded `reap_oldest` selection states that it also authorizes later local eviction of blocks whose archive copy was reaped) on `RecordingArchiveSettings`; catalog-derived object usage per binding including uploads in flight; non-reapable bytes (held archive bytes plus uploads in flight).
- [ ] C.20 serviceradar_core_elx: object reaper in the retention job (archive copies only, oldest unheld blocks first; a remaining local copy is kept and the entry recorded as local only after archive reaping, never re-archived; audited dispositions with reason `object_capacity` recording whether the local copy remained; at most 500 blocks per pass, usage re-read each pass); `stop_archiving` pause of archive jobs with blocks kept pending; non-reapable-bytes stop; gap reason `archive_capacity_exhausted` when the local tier then fills.
- [ ] C.21 serviceradar_core_elx: health checks `storage.recordings.object_capacity_binds`, `object_days_to_high_water`, `object_used_percent`, `object_overage_active`, `object_held_exceeds`, `object_archive_paused_capacity`, plus `held_archive_missing`; one OCSF event per reaper pass that deletes, through `OcsfEventPublisher.publish/2` (family `:camera`). The calculation itself is F.1.
- [ ] C.22 web-ng: `retention` tab object budget, watermarks and policy with the "can delete the last copy, including by later local eviction of blocks whose archive copy was reaped" statement before confirmation; effective object retention beside configured retention; how much footage exists only on local storage and from when; read-only when a storage entitlement is applied (F.5).

### Verification
- [ ] C.12 Tests: reaper keeps usage within budget by deleting archive copies only; bucket full with a large local volume keeps local history as local only after reaping, never re-archived; a reaped block is later evicted locally under the local budget; a held block is neither reaped nor loses its pinned copy; `stop_archiving` pauses archiving without deleting and recording continues locally; held archive bytes alone stop archiving with a critical alert; held blocks' local copies evictable once archived and pinned before; a held archive copy failing re-check moves the pin back; budget eviction from high to low water with archiving on; unlimited maximum local age evicts local copies only by budget while object retention deletes expired archive copies and keeps the local copies as local only; local-only with no destination records, plays, holds and retains with no archive work; maximum-age eviction; unarchived, unreconciled and pinned held copies never evicted; archive outage fills the volume, admission stops with a gap and alerts, then recovers; local-only ring buffer skips held blocks; local-only stop when full and unset policy behave the same; a mixed member evicts a local-only camera's oldest block under `overwrite_oldest` in one oldest-first order; a mixed member with `stop_when_full` counts local-only footage as pinned and reports it; a pending or failed upload is never selected, including by `overwrite_oldest`; a `not_required` block on a mixed member is not aged by `max_local_age` and is aged by `local_only_max_age` under each full policy; the per-kind window and pinned-growth time-to-full match the design C1a worked examples; turning archiving off moves pending entries to `not_required` and enqueues nothing; uploads continue between object low and high water when T is 0; held footage filling the budget stops recording; alerts deduplicate and clear; hold before and after deletion intent; terminal states not revived by archive jobs, receipt import or registration; NVR crash mid-reclaim; versioned delete never uses a bare delete marker; object retention unenforced without a retention credential.

## D. Unified timeline playback (design D)

### serviceradar_nvr and serviceradar_nvr_client (parallel)
- [ ] D.1 Read listener: `GET /v1/blocks/<id>/init` and `/fragments/<n>` with expected descriptor digest; separate mTLS pin and read token; separate playback read pool (default 8); chart NetworkPolicy from web-ng to the read port.

### serviceradar_core_elx (parallel)
- [ ] D.2 Isolated archive reader per-request credential mode for CNPG-credentialed bindings (operator-created or Cloud-delivered): per-request destination, reader credential and exact plan; key-family check; admission install bound (default 8).

### web-ng
- [ ] D.3 Timeline API: coverage, playlist across blocks (design D2), init and fragment with copy resolution and digest check (design D3), `source` forcing, `X-Recording-Copy`, bounds (design D4).
- [ ] D.4 Authorization on every request and `RecordingAccessAudit` per playlist window (design D7); resource and migration in serviceradar_core.
- [ ] D.5 Timeline mode on `/cameras/:camera_source_id/recordings`: coverage bar with copy states (including local only after archive expiry or reaping), gaps, not scheduled and deleted regions; time basis labels; automatic adjacent-window loading; served-copy indicator; holds. No database queries in disconnected mount.

### Verification
- [ ] D.6 Synthetic footage played across a local-to-archive boundary, after local reclaim, after NVR loss, with forced sources, across a gap and across an epoch change; an independent decoder checks frames. Browser qualification of discontinuities and gap handling with the pinned hls.js.

### Later (not in this change's acceptance)
- [ ] D.7 Multi-camera synchronized scrubbing.
- [ ] D.8 `camera_reported` time basis from validated RTCP mappings.
- [ ] D.9 Shared fragment cache.

## E. Settings and UI surface (design E)

- [ ] E.1 `policy` tab: per-camera policy table with bytes-per-day estimates per profile and the what-if panel before saving (projected window, archive throughput against goodput, blocks per day against the cap, sessions against the limit).
- [ ] E.2 New `retention` tab (added to the view's `supported_tabs/0`): watermarks, maximum local age with "no limit", alert threshold, local-only full policy with explicit confirmation, local-only target and maximum age with "keep until the volume is full", archive retention with "no limit"; preview of what a change would evict before saving; fully usable with archiving off. `archive` tab: retention credential slot, and "Local only: no object storage configured" as a normal state.
- [ ] E.3 `health` tab: per member "local storage holds about N hours/minutes at the current rate" with its binding bound, used and pinned bytes against watermarks, time-to-full, current storage alerts, retention status, gaps by reason, ledger state.
- [ ] E.4 Update `add-nvr-operator-settings` in whichever change lands second: its hot-window requirement becomes a maximum local age (ceiling) with capacity eviction, and its D13 local-only wording becomes the explicit full policy (design E2).

## F. SaaS storage entitlements (design F)

Control-plane work (pool, allocations, floors, portal split, 24 h pending
decrease, provider sampling, metering, billing, notices) is in the control
storage-entitlements issue and #182, referenced, not repeated here.

### P1: calculated retention and usage figures (no control dependency)
- [ ] F.1 Shared calculator (serviceradar_core, pure functions): per-policy rates (24 h and 7-day mean, nominal estimate with the 1.02 overhead), the common cutoff T solved piecewise, effective retention and binding bound per policy; unit tests for vectors V1-V6 (design F5), published so control copies them.
- [ ] F.2 web-ng: retention tab shows archive size, held bytes, rates and "holds about N days" per policy with configured versus effective and the binding bound; what-if before saving; self-hosted operator budget with alerts only while the reaper flag is off.

### P3: entitlement contract and delivery (depends on control issue)
- [ ] F.3 serviceradar_core: `StorageEntitlement` singleton resource and migration (revision, canonical SHA-256, applied time, per-consumer fields, pending block), PaperTrail audited.
- [ ] F.4 web-ng: `entitlements` purpose in the control-plane runtime auth plug (token, `X-ServiceRadar-Deployment-Ref`, `X-ServiceRadar-Entitlement-Generation`); `PUT` and `GET /v1/storage/entitlement` with schema validation, revision ordering, idempotent replay and refusal of unknown fields; hosted install holds archive admission until applied.
- [ ] F.5 serviceradar_core and web-ng: settings bounds from the entitlement (read-only object budget and policy, retention bounded by `max_days` with "limited by your plan", configured versus effective, camera limit on policies); pending change display and application at `effective_at`.
- [ ] F.6 web-ng and serviceradar_core: `GET /v1/storage/usage?from=` (closed UTC days, bounded pages, report revisions, opaque policy references) and current-day gauges on `/metrics`.

### P4: reaper under an entitlement (depends on control plan terms)
- [ ] F.7 Enable the C3a reaper for `reap_oldest` from the entitlement (archive copies only; remaining local copies stay as local only under the local rules); capacity policy recorded with the entitlement revision.

### Parallel: credentials (depends on control #182)
- [ ] F.8 web-ng and serviceradar_core: `PUT /v1/media/archive-credentials/:role` (writer, reader, retention) writing `network_credential_secrets` rows marked `managed_by = control_plane` with a generation, pointing the settings slots; GET with generation and status only; read-only rows and "Managed by ServiceRadar Cloud" in the credential-usage inventory; rotation with destination test and drain of the previous generation.

### Later: lifecycle (depends on control lifecycle workflow)
- [ ] F.9 Suspension through the existing durable recording stop with retention and reaping continuing; `GET /v1/storage/holds?cursor=` held-object manifest for termination; holds never deleted by deprovisioning.

### Cross-change
- [ ] F.10 Request an amendment in `add-vms-storage-playback-engine`: its `cloud-control-plane.md` custody text and the `mediaStorage.providerSecretName` path either migrate to the credential broker or are recorded as the one infrastructure exception; this change keeps every NVR archive credential in the CNPG inventory (design F7).
- [ ] F.11 Tests: revision ordering, replay and refusal; hosted hold before the first entitlement; self-hosted unaffected; bounds and pending application; usage report replay; managed credentials read-only; rotation drain; suspension keeps holds and retention.

Out of scope: the StarRocks warehouse consumer, a separate product follow-up under the same allocation contract.

## Validation

- [ ] V.1 `openspec validate add-nvr-retention-and-timeline-playback --strict`.
- [ ] V.2 Each stage runs remote builds and tests and goes through the no-mistakes gate; fixtures are synthetic.
