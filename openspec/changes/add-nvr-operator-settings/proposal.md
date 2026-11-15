# Change: Operator settings for NVR recording and archive storage

## Why

The standalone NVR can capture a bounded block from an inventory camera, and the
first archive slice copies a sealed block to an S3-compatible bucket through
Longshore and writes a verified receipt beside the local copy. Every one of those
steps is reachable today only through `bin/... eval` or hand-edited Kubernetes
objects. There is no Settings page for cameras, NVR, VMS, recording or object
storage: searching "camera" in the Settings command palette returns nothing.

An OSS operator must be able to see whether recording is installed and admitted,
choose where archives go and which stored credential writes them, start the
operations that exist today, see where each recorded block lives, and prove that
footage can be retrieved from both the local NVR copy and the object-storage copy,
without an AI agent and without hand-run commands.

## What Changes

- Add a **Recording & Storage** view to the Settings catalog
  (`/settings/recording`) under a new System parent group, found by Ctrl+K
  keywords such as camera, NVR, VMS, recording, archive, S3 and bucket. It is
  always listed for permitted users and reports explicit states (NVR not
  installed, recording disabled, recovery gate closed, archive not configured,
  upload failing) instead of empty pages.
- Add three RBAC keys: `settings.recording.view`, `settings.recording.manage`
  and `settings.recording.operate`. Footage reads keep the existing
  `devices.cameras.recordings.view` check.
- **Stage A (implementable now, after the archive slice merges):**
  - Recorder status: NVR members, storage IDs, readiness, Core and per-member
    recovery gate state, and capacity. The UI reports the gate; it never opens it.
  - Archive destinations: operator-created immutable destination generations
    (endpoint, region, bucket, key prefix) on the existing `ArchiveBinding`, one
    active destination, and selection of an `s3_compatible` credential from the
    unified CNPG inventory by reference. The page never accepts key material.
  - A destination connectivity test run by each NVR member, which is the
    component that uploads.
  - Per-camera operations that exist today: a bounded capture to a chosen NVR
    member and archiving one sealed block, run under core-elx supervision with
    durable outcomes.
  - A per-camera block list showing, per copy, whether the block is local,
    archived, both, missing or unknown, with receipt details. It also offers
    retrieval checks that re-read and hash the local copy and the archive copy
    independently.
  - Core persistence of archive receipts. The archive slice writes the receipt
    only on the NVR volume, and the UI needs it in CNPG.
- **Stage B (specified, blocked on recording-plane tasks):** continuous
  recording policy per camera/profile, hot local retention (default 24 hours)
  with archive-gated reclamation, upload backlog and archive health, and
  playback that can be forced to the local copy or the archive copy.
- Runtime choices (destination, credential, policy, retention) live in CNPG with
  code defaults. Install topology (NVR replicas, storage IDs, workload mTLS,
  provider egress, recovery gate) stays deployment-owned.

## Impact

- Affected capability: `camera-recording` (ADDED requirements only). Settings
  navigation mechanics are already owned by the pending
  `redesign-settings-catalog-nav` change; this change adds one catalog entry.
- Related pending work:
  [scalable recording plane](../add-scalable-camera-recording-plane/proposal.md)
  owns placement, storage modes, reclamation and playback contracts; Stage B
  depends on its tasks 2.2, 2.4, 3.2, 3.3, 3.4, 3.5 and 3.7.
  [VMS storage and playback](../add-vms-storage-playback-engine/proposal.md) stays
  authoritative for catalog, playback, holds and retention.
  [Longshore](../add-longshore-object-storage/proposal.md) owns the object-storage
  client. [Local-copy registration](../define-nvr-local-copy-registration/proposal.md)
  owns local catalog registration; until it lands, Core does not register NVR
  blocks as playable.
- Affected code (Stage A): `elixir/web-ng` (catalog entry, router, new LiveView,
  links from camera pages); `elixir/serviceradar_core` (RBAC catalog, new
  `Camera` resources and migrations, `ArchiveDestination` v2, credential usage
  inventory and destroy guard); `elixir/serviceradar_core_elx` (an operations
  facade, receipt persistence, NVR member listing); `elixir/serviceradar_nvr`
  and `elixir/serviceradar_nvr_client` (status, lookup, receipt, probe and
  verify endpoints); docs.
- No Helm value is added for any runtime choice. No credential leaves CNPG except
  inside a single authenticated NVR request, as the archive slice already does.
- This change does not enable continuous recording, reclaim local media, publish
  NVR blocks to the playback catalog or qualify a provider.
