## 1. Implementation
- [x] 1.1 Add `GuestIdentityGuard`: classify live `integration_id` values as Proxmox v3 and v2 guest identities, and refuse a pair whose sets, within a generation, are both non-empty and neither contains the other.
- [x] 1.2 Run the guard in `MergeEngine.merge_devices/3` for every merge reason except `manual*` and `unmerge`; record the refusal as a `guard_block` decision whose evidence carries both sets.
- [x] 1.3 Add the guard to the fingerprinted guards and bump the `BlockFingerprint` rule version.
- [x] 1.4 Database tests: four guests of different VMIDs refused by `hypervisor_guest_network_match` against a record holding other guests, with the decision evidence and the manual bypass; a `identifier_backfill` pair refused and skipped while unchanged; a guest seen again under its reference; an AWX record and an agent's record merging into a guest; a retired reference not blocking a merge or a source succession.
- [x] 1.5 Unit tests for guest identity classification and the set comparison (kinds, clusters, integrations, subsets, generations).
