## 1. Implementation

- [ ] 1.1 Audit existing relay ownership and edge-record contracts, including #4905. Use independent viewer/recorder/analysis leases so recording survives the last viewer leaving without a second RTSP connection.
- [ ] 1.2 Prototype supported H.264 keyframe-aligned segmentation and actual browser seek/reconnect before freezing container, initialization, duration/byte bounds and discontinuity behavior. Do not promise arbitrary codecs.
- [ ] 1.3 Add authorized policy, fenced recorder ownership and segment-index Ash resources/migrations.
- [ ] 1.4 Stream finalized immutable media/init objects to permanent S3-compatible storage using bounded buffers/spool. Verify length and checksum; persist recoverable manifests and idempotent index publication.
- [ ] 1.5 Reconcile restart, upload/index boundary failures and orphan/multipart state. Never advertise partial footage as available or invent clock continuity.
- [ ] 1.6 Plugins register sources through host interfaces; a long-lived media worker owns capture. Camera credentials remain in the unified credential inventory; media-storage credentials are infrastructure credentials.

## 2. Acceptance

- [ ] Synthetic RTSP -> shared ingest -> verified object storage -> indexed segment -> browser prototype succeeds.
- [ ] Multiple viewers plus recording use one ingest; viewer exit and recorder overload do not break the other consumers.
- [ ] Keyframe absence, reconnect and codec/time discontinuity produce bounded explicit gaps.
- [ ] Failure injection at each upload/manifest/index boundary recovers without duplicate timeline entries or false availability.
- [ ] Integrity mismatch and unauthorized policy/source access fail.

## 3. Delivery

- [ ] 3.1 Validate this proposal with openspec validate --strict and run applicable remote checks.
- [ ] 3.2 Run make test and deliver code changes through no-mistakes with the srql-fixtures-only database restriction in the intent.
- [ ] 3.3 Record evidence and close only this issue after its own acceptance passes.
