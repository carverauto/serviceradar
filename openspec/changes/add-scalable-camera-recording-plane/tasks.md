# Implementation plan

This is a planning checkpoint. Every implementation and deployment task remains
open until its own evidence exists. The synthetic capacity ladder is a target,
not a shipped camera-count guarantee.

## 1. Contracts and qualification design

- [ ] 1.1 Review/approve the three supported modes, independent recorder tier and no-JetStream-media decision.
- [ ] 1.2 Specify source routing/consumer lifecycle and assignment/handoff transitions, including all crash and partition boundaries.
- [ ] 1.3 Specify finite offline grants, conservative expiry/reboot behavior and provenance-checked historical reconciliation without weakening stale-owner fences.
- [ ] 1.4 Define local durable publication/restore/hold guarantees separately from provisional spool and S3 archive proofs.
- [ ] 1.5 Select measurable per-mode coverage, latency, outage, recovery, retention and cost SLOs; record supported codec/hardware profiles.
- [ ] 1.6 Reconcile the core-attached persistence rollout with recorder-pool packaging before a production controller conversion.

## 2. Recorder and source lifecycle

- [ ] 2.1 Extract/package the existing recording primitives as an independent service with remote Bazel artifacts and resource limits.
- [ ] 2.2 Add deployment-scoped pools, enrollment/capabilities, capacity reservations and explicit source/profile ownership.
- [ ] 2.3 Route cloud and customer-local ingest to the assigned recorder; preserve agent ownership and bounded authenticated media transport.
- [ ] 2.4 Maintain recording without viewers and attach viewer/analysis consumers to the same source; preserve current viewer-only behavior.
- [ ] 2.5 Implement drained handoff, fencing, volume preservation, restart recovery and explicit unresolved/gap states.

## 3. Storage modes and recovery

- [ ] 3.1 Install qualified exclusive per-recorder filesystem volumes with explicit identities/initialization for Kubernetes and supported customer hosts.
- [ ] 3.2 Implement continuous bounded sealing, durable journal/outbox and capacity/pressure admission with reserved control space.
- [ ] 3.3 Implement local-only durable catalog/manifest publication, owner-aware authorized playback, retention/holds and restore without S3 or SaaS calls.
- [ ] 3.4 Complete qualified S3 upload/multipart reconciliation, recoverable manifests and receipt-based reclamation; preserve every existing provider/security check.
- [ ] 3.5 Enforce outage/catch-up budgets and independent archive/index availability; test `U <= R`, full disk, restart and lost responses.
- [ ] 3.6 Implement explicit mode/data-residency transitions without retargeting or deleting historical media.

## 4. Customer hardware, workers and Cloud

- [ ] 4.1 Implement customer-host enrollment, signed updates, supported architecture checks and bounded offline operation.
- [ ] 4.2 Implement metadata-only durable analysis queues and independent CPU/GPU admission, with slow-worker/expired-job isolation proof.
- [x] 4.3 Scope/file linked control-plane work for customer pools and mode-aware provisioning: [Cloud #191](https://github.com/carverauto/serviceradar-control/issues/191) records the extensions to #182/#183/#184/#190 in cloud-scope.md. This completes issue scoping only.
- [ ] 4.4 Implement mode-aware desired/applied reporting, quotas, metering, credential custody and preservation-aware lifecycle in Cloud.
- [ ] 4.5 Verify complete on-prem operation needs no SaaS entitlement/heartbeat or object storage when local-only mode is selected.

## 5. Acceptance and rollout

- [ ] 5.1 Preserve existing media, ownership, storage, publication, permission and browser assertions; add behavior tests through actual service/protocol boundaries.
- [ ] 5.2 Execute the synthetic 100/1,000/10,000-stream ladder, steady-state soak and independent generator qualification with explicit SLO failures.
- [ ] 5.3 Exercise all three deployment modes and the failure matrix in capacity-and-acceptance.md, including local-only recovery and concurrent live viewing.
- [ ] 5.4 Run remote builds/tests and full make test; deliver each implementation through Treehouse/no-mistakes with remote rc files in every checkout.
- [ ] 5.5 After synthetic qualification and explicit deployment approval, run bounded live acceptance and verify test-resource cleanup; keep operational identifiers/media private.
- [ ] 5.6 Publish measured supported profiles and unresolved limits; do not infer support from design, estimates, installed PVCs or visible GPUs.
