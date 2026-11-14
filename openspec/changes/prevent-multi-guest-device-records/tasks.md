## 1. Prevent
- [x] 1.1 Add `GuestIdentityGuard.added_guests/2` and a batched read of the live v3 guest references records hold.
- [x] 1.2 `BatchResolver`: refuse a final target that would gain a second guest, resolve to the guest's own reseeded uid, claim in-batch, record a `guard_block` decision and telemetry.
- [x] 1.3 Attach backstop in `IdentifierRecords.bulk_upsert_identifiers/1` and `Registrar.register_identifiers/3`.
- [x] 1.4 Merge guard: refuse a merge that gives the survivor a second guest.
- [x] 1.5 Database tests: resolution across two integrations and within one, the device-id hint, the same guest again, a guest-less record taking a guest, a retired reference; the attach backstop; the merge survivor rule. The cross-integration resolution test fails on the code before 1.2.

## 2. Repair
- [x] 2.1 `MultiGuestSplit` planner: candidates, ownership proofs, keeper, unproven rows.
- [x] 2.2 `multi-guest-split` step: dry run report, runtime execute gate (`enable_multi_guest_split_execute`), synced manifest, one transaction per record with a re-plan under the lock, distinct assertions, revision bumps, outcome accounting.
- [x] 2.3 `source-id-rollback` reverses `guest_split` entries.
- [x] 2.4 Read-only `multi-guest-verify` step.
- [x] 2.5 Database tests: a two-integration record split along a linked AWX host, a one-integration record, an unproven MAC, conflicting bindings, the gate, and rollback.

## 3. Operation (owner)
- [ ] 3.1 Dry run on a deployment and review every planned split and unproven row.
- [ ] 3.2 Execute with the runtime gate enabled, then disable the gate.
- [ ] 3.3 Run `multi-guest-verify` after the next sync of every Proxmox integration.
