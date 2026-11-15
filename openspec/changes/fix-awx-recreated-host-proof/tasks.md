## 1. OpenSpec
- [x] 1.1 Proposal records the false positive, the supersession rule, and the D6 supersession note
- [x] 1.2 MODIFIED requirement refines the proof definition + new re-created-host scenario
- [x] 1.3 `openspec validate fix-awx-recreated-host-proof --strict` green

## 2. Fail-first regression test, then implement
- [x] 2.1 New DB test: merge proved by a superseded-vs-current host pair plans no unit (red before fix)
- [x] 2.2 Companion cases: two current hosts still prove bad; different inventories still prove bad
- [x] 2.3 `load_around` loads membership snapshot (live identifier rows plus the merge audit snapshots the proof reads); `merge_input` attaches it; `different_awx_hosts?` canonicalizes
- [x] 2.5 Review follow-up: fixture archives the retired identifier row so the loader must find the old id in the audit; loader collects audit ids
- [x] 2.4 Existing planner tests keep passing unchanged (no-membership default preserves behavior)

## 3. Gate and land
- [x] 3.1 Format, diff-check, Bazel quality gate
- [ ] 3.2 No-mistakes gate (grok reviewer), PR against staging, merge --merge
- [ ] 3.3 Demo read-only dry run: verify passes A2/A3 on the re-created-host merge; unfiltered unmerge dry run plans 0 units for it
