# Implementation and validation plan

Implementation is in progress. [The handoff](README.md) owns the current pickup
point and evidence. A merged planning PR does not complete any runtime, cloud
or live acceptance task below.

## 0. Review and feasibility gates

- [x] 0.1 Approve consolidated scope, PRD dispositions and cross-repository ownership; leave #4913/#4915 open until acceptance.
- [ ] 0.2 Audit existing relay/agent ownership and #4905 record provenance; specify recorder fencing and one-ingest behavior.
- [ ] 0.3 Pin media libraries; prove H.264 CMAF packaging, init/byte map, keyframe bounds, browser seek and reconnect using synthetic RTSP.
- [ ] 0.4 Measure audio/HEVC capability and clock uncertainty; select supported codec/profile/browser matrix and synchronization tolerance.
- [ ] 0.5 Validate provider endpoint range/checksum/multipart/policy/lock capabilities and private access probes.
- [ ] 0.6 Measure block/index/WAL/cache/object request costs; choose format bounds and service objectives instead of assuming PRD KPIs.
- [ ] 0.7 Evaluate stream-doctor's supported A/V-drift scenario in a Bazel/RBE test target with synthetic media; prove a deliberately delayed stream fails.
- [ ] 0.8 Specify versioned runtime/cloud and GPU job/result contracts, capability negotiation and invalid/unauthorized input behavior.

## 1. Recording and immediate playback

- [ ] 1.1 Add Ash policy/lease/block resources and migrations, independent consumer leases and fenced recorder takeover.
- [ ] 1.2 Implement bounded append/journal/seal and complete-fragment high-water publication; separate packer writes from range readers.
- [ ] 1.3 Implement immutable upload, checksum/init/manifest verification and idempotent index publication.
- [ ] 1.4 Reconcile restart at every local/upload/manifest/index boundary; handle disk loss, stale owners, orphan/multipart state and explicit gaps.
- [ ] 1.5 Add authorized local/archive range gateway and bounded HLS windows; deny unauthorized ranges and whole-object leakage.
- [ ] 1.6 Integrate timeline/player and spatial links; preserve viewer cleanup and live-view behavior.
- [ ] 1.7 Ship disabled by default with storage/capability validation, admission budgets and observability through JetStream/EventWriter.

## 2. Production lifecycle and Cloud

- [ ] 2.1 Complete C1 media provisioning/security issue and runtime readiness handshake before automated hosted enablement.
- [ ] 2.2 Implement byte-bounded cache and freshness-aware timeline/motion aggregation; benchmark compression separately.
- [ ] 2.3 Implement transactional hold/export/delete claims, verified evidence copies, version-aware deletion and protected metadata retention.
- [ ] 2.4 Implement bounded MP4 exports, optional audio conversion and measured HEVC/replay capabilities.
- [ ] 2.5 Complete C2/C4 quotas/metering/suspend/terminate issue; prove generic provider cleanup cannot purge protected media.
- [ ] 2.6 Implement credential rotation, provider drift handling and archive/index restore drills.
- [ ] 2.7 Complete C3 GPU placement/identity issue and provision isolated queue/worker resources with measured capabilities.
- [ ] 2.8 Implement durable worker admission/outbox, bounded redelivery/deadlines, idempotent completion, cancellation and cleanup.
- [ ] 2.9 Benchmark RPC versus JetStream using comparable jobs; reserve interactive capacity and prove worker failure isolation.

## 3. Optional derivatives and follow-on proposals

- [ ] 3.1 Specify and prototype Whisper transcripts with time-aligned text, search authorization, text/semantic retrieval, model versions and retention.
- [ ] 3.2 Specify sampled thumbnails/CLIP projections and bounded index/backfill costs; resolve projection versus telemetry ownership before schema work.
- [ ] 3.3 Add player location/camera/time overlays with capture-time metadata; prototype optional burned-in text/logo exports and measure encode cost.
- [ ] 3.4 Evaluate Smelter composition and actual GPU/ARM64 support independently of core recording.
- [ ] 3.5 Coordinate PostGIS field-of-view and OCR/POS search with spatial/observation owners; select extensions through measured compatibility gates.
- [ ] 3.6 Extend #4914 with high-quality local/substream policy and on-demand historical fetch without weakening offline admission/archive receipts.

## 4. Release acceptance and delivery

- [ ] 4.1 Synthetic RTSP -> one shared ingest -> complete local fragment -> verified archive/manifest -> index -> browser seek succeeds.
- [ ] 4.2 Last viewer exit, recorder/GPU overload, reconnect, missing keyframes and uncertain clocks preserve other consumers and expose honest gaps.
- [ ] 4.3 Inject failure at append/journal/seal/upload/complete/digest/manifest/index/ACK boundaries; verify exact synthetic interval/digest inventories and no duplicate timeline/results.
- [ ] 4.4 Deny guessed identities, unauthorized ranges, expired handles, public bucket access and cross-environment worker/storage access.
- [ ] 4.5 Race holds and exports with retention/termination; verify object/version deletion before metadata removal and prove holds survive restore.
- [ ] 4.6 Validate overlay history after a camera rename; derivatives preserve original checksums; transcripts/search cannot reveal unauthorized or expired media.
- [ ] 4.7 Run synthetic scale tests with declared workload, p50/p95/p99, storage/API/egress/GPU cost and explicit resource ceilings.
- [ ] 4.8 After synthetic proof, run bounded acceptance in the operator-designated existing test namespace/camera/GPU pool; create isolated private buckets with linode-cli and verify cleanup. Keep real data out of committed artifacts.
- [ ] 4.9 Validate OpenSpec strictly. Use Treehouse with linked Bazel rc files, remote RBE only, independently invented fixtures, scratch srql-fixtures DB tests and cleanup for committed rows.
- [ ] 4.10 Run required checks and make test; send every PR through no-mistakes targeting a feature branch. Record every check not run.
- [ ] 4.11 Stop admission and drain/preserve state for rollback; close each tracking issue only after its own runtime/cloud acceptance passes.
