## 1. Contract review

- [x] 1.1 Approve the qualification authority, immutable registration tuple, historical retry behavior and restore boundaries in design.md.
- [ ] 1.2 Select explicit qualification-validity, health-age and supported restore-horizon limits for the first provider profile before enabling it.

## 2. Implementation after approval

- [ ] 2.1 Add immutable storage bindings/reports, current eligibility and scoped activation/withdrawal without qualifying existing installations automatically.
  - First checkpoint: immutable `LocalStorageBinding` generations retain exact provider/profile identity and original provisioning provenance; scoped provisioning refuses conflicting retries.
  - Second checkpoint: immutable `LocalStorageQualificationReport` revisions retain bounded outcomes, evidence digests, policy revisions and original issuing provenance against the exact binding/profile. Scoped qualification principals can retain reports but cannot provision bindings; retention does not verify evidence or freshness.
  - Third checkpoint: scoped report assessment checks explicit trusted policy, Core time, required outcomes and exact-report health evidence. It returns a bounded current-evidence interval without activating qualification.
  - Fourth checkpoint: scoped activation/withdrawal uses one conditional-upsert decision row per storage lifetime, ordered revisions, transaction-time evidence checks and policy snapshots. Current status fails closed on expiry or policy changes; reports remain immutable. Registration/history serialization remains in task 2.4.
- [ ] 2.2 Implement explicit new-volume history bootstrap and supported publication/preservation/disposition reconciliation for retained volumes.
  - First checkpoint: Core retains one immutable bootstrap preparation per storage lifetime, bound to a scoped provider binding and caller-selected operation UUID. Exact retries preserve canonical bytes and provenance; changed operations/bindings conflict. Preparation grants no history eligibility.
  - Second checkpoint: the explicit offline NVR installer persists bounded canonical preparation bytes on a private empty root before the storage marker. Exact retries sync original bytes and can finish a missing marker; existing spools and partial/conflicting evidence are refused. Inventory/admission stay closed until two-sided completion. Packaged-release tests own installation and interruption-state recovery; two-sided completion and retained-volume reconciliation remain pending.
  - Third checkpoint: Core retains a scoped provisioner installation acknowledgement bound to the exact immutable preparation UUID and SHA-256. Exact retries preserve canonical bytes and original provenance; missing/foreign preparation or mismatched evidence is refused. This records the trusted provisioner attestation, not a physical write proof or a completed history checkpoint. Volume acknowledgement persistence, accounting, completion reconciliation and retained-volume recovery remain pending.
- [ ] 2.3 Add bounded registration/acknowledgement codecs and NVR durable sidecars, inventory, control reservations and recovery.
- [ ] 2.4 Add the Core registration resource/transaction and authenticated receiver, with exact retries and qualification/history/disposition serialization.
- [ ] 2.5 Add bounded NVR registration delivery and restart reconciliation separately from unchanged v1 intent acceptance.
- [ ] 2.6 Integrate current owner routing and fresh authorized playback under the separate transport/read-admission contracts.

## 3. Evidence and rollout

- [ ] 3.1 Exercise all design.md failure cases at their owning database, release and provider boundaries using synthetic fixtures.
- [ ] 3.2 Qualify actual worker-node/local-disk loss, exclusive reattachment and retained history for the selected provider profile.
- [ ] 3.3 Run required remote tests and green CI for each implementation checkpoint; keep unexecuted capabilities explicitly unqualified.
- [ ] 3.4 Obtain explicit deployment approval before enabling recording or executing destructive qualification against an environment.
