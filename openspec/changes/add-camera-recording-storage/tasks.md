## 1. Recording contract and prototype
- [ ] 1.1 Review recorder leases, fencing, time mapping, recording/index identities and media policy against the existing camera relay and edge record contracts.
- [ ] 1.2 Prototype supported H.264 segmentation plus real-browser seek/reconnect; freeze container, segment limits, initialization and discontinuity contracts before exposing the API.
- [ ] 1.3 Freeze direct and disconnected-edge recording profiles, finite offline policy/credential windows and event prebuffer follow-up boundaries; no implicit codec or unlimited offline durability promises.

## 2. Durable storage and recovery
- [ ] 2.1 Add Ash resources/generated migrations for policy, lease, index and retention/export workflow, with resource-level permissions and unified camera credentials.
- [ ] 2.2 Implement bounded segment upload, digest verification, publication, retry and restart reconciliation; fault-inject each object/index commit boundary.
- [ ] 2.3 Implement retention/hold/export race handling, object-deletion verification and orphan/multipart cleanup.

## 3. Optional JetStream staging
- [ ] 3.1 Add per-deployment sizing/admission controls for TTL, max bytes, segment size, replicas, placement, reserved telemetry capacity and IO/network limits.
- [ ] 3.2 Implement temporary object staging with safe deadlines, discard-new semantics, cleanup, pressure/gap telemetry and drain/disable behavior.
- [ ] 3.3 Prove full bucket, partial upload, expiry, archival outage and replica/node pressure without changing telemetry capacity or reporting false retention.
- [ ] 3.4 Implement local-domain JetStream admission, complete-object/pending-journal reconciliation and a long-lived host archiver that starts each finalized segment immediately, independently of hub reachability.
- [ ] 3.5 Implement restart-safe upload/retry/multipart reconciliation, verified archive manifests/initialization objects, durable receipts and local reclamation without waiting for central CNPG; reconstruct missing index records from archive manifests.
- [ ] 3.6 Prove a configured multi-hour synthetic disconnection, edge/archiver restart, S3 reachable with hub disconnected, reconnect with duplicate receipts and catch-up while new capture continues; verify exact segment/digest inventory and gap accounting.
- [ ] 3.7 Prove below-ingest uplink throughput, finite TTL/capacity exhaustion, policy/credential expiry and revocation handling; expose drain ETA/time-to-full and preserve telemetry/control reservations.

## 4. Operator and dashboard surfaces
- [ ] 4.1 Add authorized timeline, seek and time-range export APIs with explicit gaps and short-lived access handles.
- [ ] 4.2 Extend existing dashboard host camera API and SDK player lifecycle; link media to provider-owned map object identities and preserve access checks.
- [ ] 4.3 Publish deployment sizing/runbook including variable bitrate, replicas, edge-vs-core outage coverage, throughput, retention and alert thresholds.

## 5. Acceptance
- [ ] 5.1 Run synthetic RTSP -> shared relay -> durable recording -> browser playback with no live/captured fixtures; automated DB tests use srql-fixtures scratch DB only.
- [ ] 5.2 Verify multiple viewers/analysis plus recording share ingest, recorder lease survives viewer exit, unauthorized access fails and slow archival does not stall live viewing.
- [ ] 5.3 Run all builds/tests on remote RBE, strict OpenSpec validation and no-mistakes before PR publication; keep recording feature disabled until measured deployment admission passes.
