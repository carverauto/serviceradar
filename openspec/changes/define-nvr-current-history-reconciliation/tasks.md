## 1. Contract approval

- [x] 1.1 Approve the explicit restore gate and independent deployment recovery generation in design.md.
- [ ] 1.2 Select supported recovery adapters, authoritative backup evidence, and numerical restore/history retention horizons before enabling recovery.

## 2. Implementation after approval

- [ ] 2.1 Implement trusted deployment recovery state and fail-closed startup/admission consumers for Kubernetes and non-Kubernetes deployments.
  - NVR checkpoint: NVR consumes external boot-pinned recovery state at admission, writer checks, publication attempts and read replies; Helm references an existing operator-owned ConfigMap. Standalone processes consume the same file contract.
  - Core publication checkpoint: Core checks local-intent acceptance before its transaction and before replying; Core and web-ng consume the same projected state.
  - Core new-work checkpoint: shared admission checks recovery before its transaction and before replying for recorder claims, block reservations, metadata dispatch preparation and provider grants. Committed work is retained after closure; preservation and stop/release operations remain available.
  - Core archive-authority checkpoint: challenge and application of init/media/manifest windows check recovery before and after their transactions. Committed revisions and original deadlines survive withheld replies; status and revocation remain available.
  - Core archive-access checkpoint: publication and reader-facing metadata, inventory and ranges check recovery before work and before replies. HTTP reads recheck after provider I/O. Historical status and late evidence remain inspectable while closed.
  - Remaining Core authority consumers, the recovery command and cross-replica quiescence verification remain pending.
- [ ] 2.2 Implement per-storage immutable history, explicit genesis and domain-owned transactional head advancement.
- [ ] 2.3 Integrate publication, preservation and disposition serialization without changing v1 intent/S3 receipt meanings.
- [ ] 2.4 Implement bounded NVR history persistence, control reservations, cursors and exact restart recovery.
- [ ] 2.5 Implement provenance-checked reconciliation and current-generation completion with stale-head refusal.
- [ ] 2.6 Replace the bootstrap barrier only after all required admission consumers use current completion and independent qualification/authority gates.

## 3. Verification and operations

- [ ] 3.1 Exercise the database and packaged-release cases in design.md with synthetic fixtures and green CI.
- [ ] 3.2 Provide the gated restore command/runbook and verify that GitOps rollback cannot silently restore ready state.
- [ ] 3.3 Verify ordinary worker replacement separately from Core-only, volume-only and coordinated snapshot restores on the selected provider profile.
- [ ] 3.4 Obtain explicit deployment and destructive-qualification approval before enabling this in an environment.
