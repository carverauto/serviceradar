# Change: Edge recording: bounded JetStream Object Store buffering and continuous S3 archival

Tracking issue: [#4914](https://github.com/carverauto/serviceradar/issues/4914).

## Why

Extend the recording foundation in `add-camera-recording-storage` to survive a configured disconnected interval. JetStream Object Store is a finite local transfer buffer; permanent S3-compatible storage is the archive. This is not part of #4774 acceptance.

## What Changes

- Bind recorder/archiver to a persistent local JetStream domain/account/bucket. Capture cannot require central CNPG or a remote Raft quorum.
- Provision finite offline policy/credential windows and fenced assignment identity before disconnect. Keep upload state in a long-lived host worker rather than stateless per-check Wasm.
- Finalize bounded objects and maintain a durable pending-work journal; reconcile a crash between object completion and journaling.
- Upload each completed segment immediately whenever S3 is reachable, independently of leaf/hub connectivity. Bound concurrency/bandwidth and persist retry/multipart state.
- Verify media, initialization objects and immutable recovery manifests; persist a receipt before reclaiming local media. Central index delivery retries separately. Manifests must recover the index after edge loss.
- A NATS leaf reconnect or PubAck is not archival proof, and does not automatically mirror Object Store contents. Any stream sourcing/mirroring is explicitly configured and tested.
- Require TTL/byte/object limits, replicas/placement, reserved telemetry/control capacity, safe upload deadlines and drain-before-disable behavior.

Related workstreams have separate proposals and acceptance checklists.

## Impact

Edge recorder/archiver, local JetStream Object Store and S3 receipt reconciliation. Depends on add-camera-recording-storage, not on central playback availability. Does not block #4774.

Proposal and tracking only; no deployment, data ingestion or recording is enabled
by this documentation change.
