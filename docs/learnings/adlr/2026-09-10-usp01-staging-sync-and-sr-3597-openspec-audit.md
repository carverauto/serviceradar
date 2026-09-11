# usp-01-proposal staging sync + sr-3597 OpenSpec audit (2026-09-10)

## 1. Branch sync

Merged `origin/staging` into `usp-01-proposal` (plain merge, no conflicts — 29
commits, fast-forward-safe merge commit `da129d9906`) and pushed directly to
`origin/usp-01-proposal`. No PR was needed: the merge was conflict-free, per
the routine-integration-branch-sync exception.

## 2. sr-3597 backlog note audit findings

The backlog note for sr-3597 ("Finish remaining OpenSpec and keep CI green on
usp-01 durable execution pipeline") needs correction, not closure:

- **PR links are stale Forgejo-era numbers.** `github.com/carverauto/serviceradar/pull/3597`
  and `.../4317` do not resolve on GitHub (`gh pr view` returns "Could not
  resolve to a PullRequest"). Per `AGENTS.md`, Forgejo issue/PR numbers do not
  map to GitHub numbers post-migration — these are dead references from before
  the cutover, not evidence the linked work vanished.
- **`usp-50-lane-accountant` no longer exists on origin** (`git ls-remote`
  confirms). No trace of "lane-accountant" or "usp-50" anywhere in the repo
  (openspec, docs, code) either — it was fully superseded/renamed, not merely
  renamed to a findable equivalent.
- **PR #12 (`feat(edge): add durable execution protocol and publishing
  foundations`, merged into staging 2026-09-08) fully completed the
  `freeze-edge-record-v1-abi` OpenSpec change** — all 12 tasks in
  `openspec/changes/freeze-edge-record-v1-abi/tasks.md` are checked off. This
  is the wire-ABI half of the durable execution pipeline (record/frame shapes,
  identity/digest grammars, enums, compatibility rules, freeze gate).
- **The runtime half is NOT superseded and is NOT done.**
  `openspec/changes/unify-sweep-results-proto/` ("Refactor the durable edge
  producer data plane") is the change that owns the actual durable-execution
  runtime: producer sinks, agent spool, gateway relay, JetStream provisioning,
  projectors, migration, and rollout, built on top of the now-frozen ABI. Its
  `tasks.md` has **102 of 106 tasks still unchecked**. Its own proposal
  explicitly states it "MUST NOT re-freeze anything the ABI change owns" and
  frames the next milestone as the first green vertical slice
  (record → agent spool → mTLS gRPC → gateway → JetStream → EventWriter →
  CNPG), which has not yet landed on staging.

**Conclusion for firstmate:** sr-3597's "finish remaining OpenSpec" ask is not
fully superseded by PR #12. PR #12 closed out the ABI-freeze half
(`freeze-edge-record-v1-abi`); the runtime half (`unify-sweep-results-proto`,
102/106 tasks open) is the concrete remaining OpenSpec work and should stay
open, retargeted at that change instead of the dead PR links / dead branch.
