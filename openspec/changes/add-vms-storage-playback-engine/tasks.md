# Implementation and validation plan

Implementation is in progress. [The handoff](README.md) owns the current pickup
point and evidence. A merged planning PR does not complete any runtime, cloud
or live acceptance task below.

## 0. Review and feasibility gates

- [x] 0.1 Approve consolidated scope, PRD dispositions and cross-repository ownership; leave #4913/#4915 open until acceptance.
- [x] 0.2 Audit existing relay/agent ownership and #4905 record provenance; specify recorder fencing and one-ingest behavior. See `ownership-provenance.md`. Relay integration is in this pass; guarded-execution evidence is in [the handoff](README.md).
- [x] 0.3 Pin media libraries; prove baseline H.264 CMAF packaging, init/byte map, keyframe bounds, Chromium seek and an explicitly restarted synthetic RTSP receiver. See the handoff evidence; other codecs and full authenticated deployment recovery remain separate gates.
- [ ] 0.4 Measure audio/HEVC capability and clock uncertainty; select supported codec/profile/browser matrix and synchronization tolerance. Test-only [codec](codec-capabilities.md) and [RTCP clock](clock-capabilities.md) experiments measure the pinned libraries; production support, clock trust/uncertainty and synchronization objectives remain open.
- [ ] 0.5 Validate provider endpoint range/checksum/multipart/atomic-no-overwrite/policy/lock capabilities, per-object encryption evidence and private access probes.
- [ ] 0.6 Measure block/index/WAL/cache/object request costs; choose format bounds and service objectives instead of assuming PRD KPIs. The [synthetic grouping experiment](block-byte-costs.md) measures local logical media/metadata bytes only; database, cache, provider and deployment measurements remain open.
- [x] 0.7 Evaluate stream-doctor's supported A/V-drift scenario in a Bazel/RBE test target with synthetic media; prove a deliberately delayed stream fails. See `stream-doctor.md`; this validates the diagnostic, not ServiceRadar audio or RTSP behavior.
- [ ] 0.8 Specify versioned runtime/cloud and GPU job/result contracts, capability negotiation and invalid/unauthorized input behavior. The [qualification report](qualification-report.md) and [private receipts](qualification-receipts.md) supply bounded observations, content identity and revisioned submission/withdrawal. [Media authentication](media-authentication.md) binds ingress to the installed deployment. [Recording control](recording-control.md) adds an origin-bound stop-only restriction. [Init authority](init-authority.md) adds one nonrenewable installation and init-operation grant; continuous recording authority, Cloud orchestration and GPU contracts remain open.

## 1. Recording and immediate playback

- [ ] 1.1 Add Ash policy/lease/block resources and migrations, independent consumer leases and fenced recorder takeover.
  - [x] Durable recorder claims, generation fencing, block reservation and frozen archive descriptors exist with guarded database coverage; see [the handoff](README.md).
  - [x] Verify provisioned spool lifetime before recorder ownership and at mutating filesystem boundaries. [Spool lifetime #6004](spool-lifetime.md) supplies the local guards; final #6007 Core CI executed the owning serial lane with all eight worker cases and successful lifecycle cleanup. Full runtime restart/takeover acceptance remains below.
  - [ ] Complete operator recording policy/admission and coordinated restart/takeover without disturbing other consumers.
- [ ] 1.2 Implement bounded append/journal/seal and complete-fragment high-water publication; separate packer writes from range readers.
  - [x] Local spool append/fsync journal/seal, complete-fragment snapshots and independent readers are implemented and covered by synthetic filesystem/media tests.
  - [ ] Integrate lifetime verification and prove recovery ownership and concurrent reader/write behavior through the runtime. [Spool lifetime](spool-lifetime.md) adds verified handles and refusal of aliased recovery files; full runtime takeover and reader/write acceptance remain open. The authorized external range gateway belongs to 1.5.
- [ ] 1.3 Implement immutable upload, checksum/init/manifest verification and idempotent index publication. [Init authority](init-authority.md) supplies conditional PUT and exact init-byte verification. [Media upload](media-upload.md) supplies an explicit bounded media caller and its separate authority; its published-head Core/Web database proof passed. The recovery manifest and idempotent index passed final #6047 Core/Web database gates. Multipart and unknown-outcome reconciliation remain open.
  - [x] Immutable destination, frozen intent and dispatch identity; isolated conditional init PUT with exact byte verification.
  - [x] Stream a bounded sealed media object under operation-specific authority and verify exact digest/length before recording success. The explicit 16 MiB [byte path](media-upload.md) passed final #6007 Core authority and both joined Web database cases, including all lifecycle cleanup. This does not enable recording or qualify a live provider.
  - [x] Write and verify the recovery manifest from the frozen descriptor after its referenced objects are verified. [Archive publication](archive-publication.md) defines the bounded implementation; [final validation](validation.md#published-head-archive-publication-validation) records its proof.
  - [x] Publish the archive index idempotently with current ownership fencing; only then expose availability. Final #6047 Core/Web database lifecycle gates passed; late conflicts still exclude availability.
  - [ ] Reconcile multipart and unknown outcomes without retargeting objects or rearming an unresolved operation.
- [ ] 1.4 Reconcile restart at every local/upload/manifest/index boundary; handle disk loss, stale owners, orphan/multipart state and explicit gaps. [Spool lifetime](spool-lifetime.md) fences local block recovery by the provisioned marker. Abandoned media scratch currently refuses restart pending operator reconciliation. Upload, manifest and index reconciliation remain open.
- [ ] 1.5 Add authorized local/archive range gateway and bounded HLS windows; deny unauthorized ranges and whole-object leakage.
  - [x] Expose [authorized single-block archive metadata](archive-metadata.md), with separate recording permission, fresh authorization and canonical conflict exclusion. Final #6055 passed all 19 checks and uncached Core/Web database lifecycle gates. Metadata never grants media access.
  - [x] Serve [authorized archive initialization and fragment bytes](archive-reads.md) through a separate bounded reader, with independent authorization before and after provider I/O. Final #6060 passed 19 checks and uncached Core/Web database lifecycles with successful cleanup.
  - [x] Assemble [bounded single-block HLS playlists](archive-playlists.md) from current canonical metadata; prove consumption through independently authorized fragment URLs. Final #6071 passed 19 checks, independent real-HTTP HLS consumption and uncached Core/Web database lifecycles; [validation](validation.md#published-head-archive-playlist-validation) records the consumer settings and repaired reload limits. Browser player and provisional local delivery remain separate.
- [ ] 1.6 Integrate timeline/player and spatial links; preserve viewer cleanup and live-view behavior.
  - [ ] Expose [bounded publication inventory](archive-discovery.md) with fresh authority, canonical availability and candidate-bounded continuation. Implementation and validation are in progress; publication order does not assert capture UTC.
  - [ ] Add a separate archive player with measured HLS seeking, cancellation and cleanup; preserve live relay ownership.
  - [ ] Add capture-time timeline and spatial links once trustworthy clock mapping and uncertainty semantics are qualified.
- [ ] 1.7 Ship disabled by default with storage/capability validation, admission budgets and observability through JetStream/EventWriter. Local marker verification and the explicit upload's single-slot byte/deadline limits are implemented; coordinated admission, observability and hosted enablement remain open, and recording stays disabled.

## 2. Production lifecycle and Cloud

- [ ] 2.1 Complete C1 media provisioning/security issue and runtime readiness handshake before automated hosted enablement. [Private archive registration](archive-registration.md) adds the immutable product binding receipt only; Cloud inventory, allocation, qualification, local storage and preservation remain open.
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
- [ ] 4.11 Stop admission and drain/preserve state for rollback; close each tracking issue only after its own runtime/cloud acceptance passes. The [recording stop checkpoint](recording-control.md) restricts recorder work and dispatch marking and requests recorder-only drain; full fleet drain attestation, storage authority revocation and lifecycle acceptance remain open.
