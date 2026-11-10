## 1. Contract review

- [x] 1.1 Approve the qualification authority, immutable registration tuple, historical retry behavior and restore boundaries in design.md.
- [ ] 1.2 Select explicit qualification-validity, health-age and supported restore-horizon limits for the first provider profile before enabling it.

## 2. Implementation after approval

- [ ] 2.1 Add immutable storage bindings/reports, current eligibility and scoped activation/withdrawal without qualifying existing installations automatically.
  - First checkpoint: immutable `LocalStorageBinding` generations retain exact provider/profile identity and original provisioning provenance; scoped provisioning refuses conflicting retries. Reports, current eligibility and activation/withdrawal are still pending.
- [ ] 2.2 Implement explicit new-volume history bootstrap and supported publication/preservation/disposition reconciliation for retained volumes.
- [ ] 2.3 Add bounded registration/acknowledgement codecs and NVR durable sidecars, inventory, control reservations and recovery.
- [ ] 2.4 Add the Core registration resource/transaction and authenticated receiver, with exact retries and qualification/history/disposition serialization.
- [ ] 2.5 Add bounded NVR registration delivery and restart reconciliation separately from unchanged v1 intent acceptance.
- [ ] 2.6 Integrate current owner routing and fresh authorized playback under the separate transport/read-admission contracts.

## 3. Evidence and rollout

- [ ] 3.1 Exercise all design.md failure cases at their owning database, release and provider boundaries using synthetic fixtures.
- [ ] 3.2 Qualify actual worker-node/local-disk loss, exclusive reattachment and retained history for the selected provider profile.
- [ ] 3.3 Run required remote tests and green CI for each implementation checkpoint; keep unexecuted capabilities explicitly unqualified.
- [ ] 3.4 Obtain explicit deployment approval before enabling recording or executing destructive qualification against an environment.
