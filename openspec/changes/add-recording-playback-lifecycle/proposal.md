# Change: VMS/NVR: authorized replay, retention holds, exports and dashboard playback

Tracking issue: [#4915](https://github.com/carverauto/serviceradar/issues/4915).

## Why

Ship operator-facing recording access and lifecycle after `add-camera-recording-storage`. Integrate `add-edge-recording-archive` states without treating temporary-only footage as permanently retained. This is separate from #4774 and independently schedulable.

## What Changes

- Authorized time-bounded timeline, seek and export APIs with explicit discontinuities, stale/index-pending states, unavailable intervals and gaps.
- Short-lived media handles; no camera credentials or reusable bucket credentials in the browser or shared links.
- Retention, holds and export leases with atomic conflict resolution, deletion verification and orphan/multipart cleanup.
- Extend the existing host camera API/SDK player lifecycle. Coordinate resource/object links with #4910; a link locates a view/object/interval but grants no access.
- Keep recording independent of viewer lifecycle; release viewer sessions when dashboards hide/unmount.

Related workstreams have separate proposals and acceptance checklists.

## Impact

Recording lifecycle APIs/workers, browser player and dashboard camera SDK. Depends on add-camera-recording-storage; coordinates with add-edge-recording-archive and add-shared-spatial-resources. Does not block #4774.

Proposal and tracking only; no deployment, data ingestion or recording is enabled
by this documentation change.
