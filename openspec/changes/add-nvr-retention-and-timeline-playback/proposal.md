# Change: NVR continuous recording, retention and unified timeline playback

## Why

The NVR path shipped today records one bounded block (at most 270 s) from the
shared camera relay into a `serviceradar-nvr` member, seals it on a replicated
volume, and copies it to an S3-compatible bucket with a verified receipt. The
local copy is kept. That proved the byte path on a live camera, but nothing
about it is automatic: no continuous recording, no reclaim of local space, no
Core record of where a block lives, no playback of NVR blocks, no object
retention, and footage from uncertain captures is stranded on the volume.

The product owner asked for:

- continuous recording that keeps as much footage locally as the volume allows
  and copies everything to object storage, or runs with no object storage at
  all;
- retention for local and object storage, every limit configurable from the
  Settings UI with sensible defaults, including keeping footage indefinitely;
- playback that does not care where the bytes live;
- nothing recorded left stranded on disk;
- purchased or fixed-size buckets that never make the product break, with the
  SaaS storage entitlement driving them on hosted deployments.

Four facts in the shipped code shape the design (details and line references
in [design.md](design.md#1-constraints-verified-in-source)):

1. A volume holds at most 4,096 blocks. Since #6660 a block holds at most
   16 MiB and 150 fragments by default, and one capture at most 270 s, 8,100
   frames or 12 MiB; the 16 MiB limit is the largest single-buffer PUT the
   object-storage client allows, and multipart upload is not implemented. A
   4 Mbit/s camera still closes a 12 MiB block about every 25 s and fills
   4,096 blocks in about 28.6 hours, and nothing frees a block. The NVR's byte
   budget is a fixed 1 GiB default, independent of the volume.
2. Recorded blocks carry `utc_mapping: "unknown"`; a wall-clock timeline needs
   an explicit time basis with honest uncertainty.
3. Uncertain captures and rotated blocks leave sealed footage with no catalog
   row, and nothing retries a failed archive.
4. H.264 is already entropy-coded, so general-purpose compression does not
   meaningfully reduce stored bytes; profile choice, retention per tier, block
   packing and request counts do.

## What Changes

Seven staged increments, each shippable on its own with explicit dependencies
([tasks.md](tasks.md) lists components, dependencies and parallel lanes). The
product owner's decisions of 2026-11-15 are recorded in
[design.md section 3](design.md#3-product-decisions-2026-11-15).

- **A. Continuous recording that fits the volume.** A per-camera policy drives a
  continuous coordinator in core-elx that records with no viewers, one block
  per ingest request of up to 270 s, 8,100 frames or 12 MiB, cut at keyframes,
  with exact gap accounting. Block sizing is the one merged in #6660 (150
  fragments per block, 16 MiB block limit). An incremental inventory ledger raises the per-volume block cap.
  Sealed blocks are archived automatically with retry and backlog reporting.
  Blocks above 16 MiB wait for multipart upload.
- **B. Core catalog of NVR blocks.** One `RecordingCatalogEntry` per sealed
  block, created only under the original recorder fence, with media and
  timeline ranges, a labelled time basis (received time, never presented as
  capture time) and where each copy lives.
- **R. Reconciliation: no stranded footage.** A periodic reconciler adopts
  sealed blocks only under Core's retained reservation authority (rotated
  blocks only on proof that they continue a reserved block), recovers
  incomplete journals, quarantines unrecoverable or unattributable footage with
  a gap (kept until an operator disposes of it), retries archive
  until it succeeds for blocks that archive (archiving enabled and policy
  `local_and_archive`), and alarms on anything it cannot attribute.
- **C. Retention and reclaim.** The local tier is a capacity-driven cache:
  budget derived from the volume and editable per member at runtime, high and
  low water marks, and a maximum local age (24 h by default, up to 10 years, or
  unlimited). The page states how long local storage holds at the current rate
  and projects it before changes. Local-only is a complete mode with an
  explicit full policy (overwrite-oldest preselected and confirmed, or stop
  when full). Object retention is enforced by ServiceRadar with a delete-only
  credential role. Holds keep at least one verified copy, preferring the
  archive. An optional object-tier budget with a recorded policy (reap the
  archive copies of the oldest footage, keeping any local copy, local only
  after archive reaping, until the local eviction rules evict it, which can delete the last copy; or stop
  archiving) keeps fixed-size buckets working, with calculated effective
  retention. Object retention and the reaper delete only archive copies, so a
  large local volume keeps its history whatever the bucket's size. Unarchived and unreconciled footage is never evicted;
  every deletion is audited and re-checked; storage alerts are deduplicated and
  auto-clearing.
- **D. Unified timeline playback.** One playback surface per camera by
  wall-clock range; each fragment comes from the local copy when present
  (labelled provisional until local-copy registration exists) and otherwise
  from the verified archive copy, verified against the same digest. Gaps, time
  basis and serving copy are visible. Reads are bounded, authorized and
  audited.
- **E. Settings.** Every runtime choice in CNPG with code defaults and explicit
  "no limit" states, editable on `/settings/recording` (new `retention` tab,
  per-member budget on `recorders`). Install values are ceilings and defaults.
- **F. SaaS storage entitlements.** On hosted deployments the product consumes
  one storage entitlement for itself (allocation, overage, plan capacity
  policy, retention maximum, camera limit, pending change, revision) over the
  private control-plane listener under its own purpose token, with no Helm
  value. It bounds the C and E settings, exposes a usage report and a shared
  retention calculation with test vectors, receives Cloud-delivered archive
  credentials into the CNPG inventory, and handles suspension and termination
  holds. Self-hosted installs have no entitlement and are unbounded by it.
  Calculated retention and usage figures come first and need nothing from the
  control plane.

This change is documents only. It adds no code, migration, chart value or
deployment change.

## Impact

- Affected capability: `camera-recording` (ADDED requirements only; the
  capability exists only in pending changes, none of whose requirement names
  are reused). `camera-streaming` is not modified.
- Builds on, does not restate:
  [scalable recording plane](../add-scalable-camera-recording-plane/design.md)
  sections 5, 6 and 9 and its
  [local publication contract](../add-scalable-camera-recording-plane/local-publication.md);
  [VMS storage and playback](../add-vms-storage-playback-engine/design.md)
  sections 2, 5 and 6; [Longshore](../add-longshore-object-storage/proposal.md).
- Decided amendments (design section 3): PD1 narrows one rule of the recording
  plane's local publication contract (a rotated block is adopted only on proof
  that it continues a reserved block); PD2 plays local copies before
  [local-copy registration](../define-nvr-local-copy-registration/proposal.md)
  exists, labelled provisional. Destructive operations wait for
  [current-history reconciliation](../define-nvr-current-history-reconciliation/proposal.md)
  after a restore.
- Composes with the pending `add-nvr-operator-settings` change: reuses its
  `/settings/recording` view, `RecordingArchiveSettings`, `NVRArchiveReceipt`,
  `RecordingOperation`, `CameraRecordingPolicy`, NVR status and lookup
  endpoints, and its backlog and forced-source playback requirements, and
  supplies the design for its blocked Stage B. Refinements it must absorb are
  listed in [design.md E2](design.md#e2-composition-with-add-nvr-operator-settings)
  (maximum local age as a ceiling, explicit local-only full policy, holds no
  longer pinning a local copy once archived, receipt version IDs, new tabs).
- Credential custody: every NVR archive credential, operator-created or
  Cloud-delivered, lives in the CNPG credential inventory. The older
  Kubernetes Secret custody text in `add-vms-storage-playback-engine` and the
  `mediaStorage.providerSecretName` path are left to that change to migrate or
  record as an exception (design F7).
- Builds on the block sizing merged in #6660 (Stage A baseline). Depends on:
  Longshore multipart (blocks above 16 MiB, later); the control-plane storage
  entitlements issue and control #182 (Stage F phases P3, P4 and credentials).
  The StarRocks warehouse consumer of the same allocation contract is a
  separate follow-up.
- Affected code when implemented: `elixir/serviceradar_nvr`,
  `elixir/serviceradar_nvr_client`, `elixir/serviceradar_recording`,
  `elixir/serviceradar_core_elx`, `elixir/serviceradar_core`, `elixir/web-ng`
  (including the private control-plane routes), `helm/serviceradar`, docs.
