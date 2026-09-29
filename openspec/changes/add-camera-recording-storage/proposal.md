# Change: VMS/NVR: shared-ingest recording leases and verified S3 segment publication

Tracking issue: [#4913](https://github.com/carverauto/serviceradar/issues/4913).

## Why

Introduce durable recording independently of live viewers, reusing the existing camera/profile ingest. This is a separate platform workstream, not required to finish #4774.

## What Changes

- Audit existing relay ownership and edge-record contracts, including #4905. Use independent viewer/recorder/analysis leases so recording survives the last viewer leaving without a second RTSP connection.
- Prototype supported H.264 keyframe-aligned segmentation and actual browser seek/reconnect before freezing container, initialization, duration/byte bounds and discontinuity behavior. Do not promise arbitrary codecs.
- Add authorized policy, fenced recorder ownership and segment-index Ash resources/migrations.
- Stream finalized immutable media/init objects to permanent S3-compatible storage using bounded buffers/spool. Verify length and checksum; persist recoverable manifests and idempotent index publication.
- Reconcile restart, upload/index boundary failures and orphan/multipart state. Never advertise partial footage as available or invent clock continuity.
- Plugins register sources through host interfaces; a long-lived media worker owns capture. Camera credentials remain in the unified credential inventory; media-storage credentials are infrastructure credentials.

Related workstreams have separate proposals and acceptance checklists.

## Impact

Existing native camera ingest/relay, recorder ownership, object-store uploader and CNPG/Ash recording index. Reuses #4848 replay sources and applicable #4905 edge primitives. JetStream staging and product playback/retention are separate changes; does not block #4774.

Proposal and tracking only; no deployment, data ingestion or recording is enabled
by this documentation change.
