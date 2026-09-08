## 1. Ground truth (complete)

- [x] 1.1 Snapshot every local branch name→tip before any deletion
      (`serviceradar-branch-restore/branches-20260821.txt`, 539 entries, + `restore-branches.sh`)
- [x] 1.2 Confirm the 519 branches deleted by the earlier sweep are disjoint from the 539
      survivors (0 overlap) — complementary sets, nothing double-counted
- [x] 1.3 Establish that this repo squash-merges, so `git branch --merged` is an unsafe
      cleanup test here (PR #2727 merge commit `83d8e5fbd` has one parent)
- [x] 1.4 Verify every one of the 539 tips is reachable from a non-`refs/heads` ref
- [x] 1.5 Flag branches reachable only via `refs/archive/jj-keep/<sha>`
- [x] 1.6 Confirm all 44 `usp-*` branches exist on the remote

## 2. Bucket triage (complete — 11-agent audit, 3 adversarial verifiers)

- [x] 2.1 `SAFE_MERGED` (38) → **DELETE**. Verified exhaustively, not sampled: 38/38 have
      `state=MERGED`, `headRefOid == local tip`, squash mergeCommit an ancestor of staging.
      Patch-identity test (branch patch vs landed squash patch) came back 37/38 byte-identical;
      the one outlier differed only in a hunk-header line number, its 156 content lines `cmp`-identical.
- [x] 2.2 `VERIFY_MERGED_NOHEAD` (21) → **DELETE**. Resolved via the GitHub compare API after
      validating its semantics against a control. 19/21 hold zero commits the merged head lacks;
      the 2 diverged ones cleared on inspection.
- [x] 2.3 `REVIEW_MERGED_AHEAD` (9) → **MIXED** (6 delete / 3 keep). **`main` resolved: it is a
      shared branch, byte-identical to `origin/main` and `github/main`.** Its "833 ahead" was a
      classifier artifact — `main` was matched to PR #2095, one of 30 PRs that used `main` as a
      head ref. True divergence from staging is 54 ahead / 6159 behind. Staging is the de-facto
      trunk; `main` is dead but may be revived, so leave the ref alone.
- [x] 2.4 `REVIEW_MERGED_OTHERBASE` (6) → **MIXED** (4 delete / 2 keep) — both keeps are usp.
- [x] 2.5 `REVIEW_CLOSED` (7) → **MIXED** (3 delete / 4 keep).
- [x] 2.6 `REVIEW_NOPR_PUSHED` (260) → **DELETE** (258 delete / 2 keep).
- [x] 2.7 `REVIEW_NOPR_LOCALONLY` (185) → **DELETE** (181 delete / 4 keep).

**Totals: 511 deletable, 28 keep.**

## 3. Critical findings — deletion is BLOCKED until these are resolved

- [x] 3.1 **Two tips have zero archive coverage — a real data-loss path.** MITIGATED: both are
      now pinned by annotated tags so they cannot be gc'd.
      - `usp-41-bounds-impl` (`c99b0e7d`) — held only by `usp-01-proposal` refs. PR #3815 merged
        it into `usp-01-proposal`, not staging. When open PR #3597 squash-merges, GitHub deletes
        the head branch, `fetch --prune` drops the remote-tracking refs, and 167 commits
        including the six signed-off edge-ABI-freeze commits become unreachable and gc-able.
        → pinned as tag `preserve/usp-41-bounds-impl`
      - `openspec/add-device-identity-fence` (`b9f0c8ce`) — same shape, content redundant with
        staging's `7e6f803ebe` but the ref itself was not durable.
        → pinned as tag `preserve/openspec-add-device-identity-fence`
- [ ] 3.2 **The archive safety net is single-copy and single-machine.** `git ls-remote origin
      'refs/archive/*'` returns 0 against 8609 local refs, and the fetch refspec is
      `+refs/heads/*:refs/remotes/origin/*`, so no fetch or fresh clone restores it. With a
      1.92 GiB pack and 7554 loose objects, "just re-clone the bloated repo" is the ordinary,
      safe-feeling remedy that would permanently destroy those commits once local names are gone.
      **Decide retention (task 6.2) BEFORE any deletion.**
- [ ] 3.3 **The name→sha index is untracked and on the same volume as `.git`.** Archive refs are
      named by sha, and 8084 of 8609 match no branch tip, so
      `serviceradar-branch-restore/branches-20260821.txt` is the only name→sha mapping. Copy it
      off-machine. Also fix `restore-branches.sh`: it uses `git branch -f`, so a no-arg re-run
      would force-move an already-recreated branch back to its 2026-08-21 sha.
- [x] 3.4 Remove the stray `diff.renameLimit=0` an audit agent left in `.git/config`.
- [x] 3.5 **`bug/sweep_results_missing_armis` — resolved: not exposed, but never push it.**
      The branch commits `tls/demo-staging/` cert bundle tarballs (`certs-backup.tar`,
      `cloud-certs.tar`, dated cert archives, CSR configs — 61 files) plus ~350 MB of Mach-O
      binaries including a 136 MB profiler. **carverauto/serviceradar is a PUBLIC repo.**
      Verified the cert-bearing commit `bd6bc1dd84` is on **0 remote refs** — absent from both
      `origin` and `github` — so nothing has been disclosed. The risk is entirely prospective:
      pushing this branch would publish demo-staging key material to a public repository.
      No GitHub issue was filed, because a public issue naming those paths advertises the
      material without protecting it. Actions: never push this branch; delete the local ref
      once the orphan `pkg/` files are extracted; treat the demo-staging certs as
      rotate-if-in-doubt.

## 4. Classification defects to carry forward (found by adversarial verification)

- [x] 4.1 The `archiveOnly` column conflated "held by a durable archive ref" with "happens to be
      an ancestor of another branch's remote-tracking ref" — this is what hid `usp-41-bounds-impl`.
- [x] 4.2 Wrong-PR matching: 7 branch names were reused across PRs and the classifier always took
      the highest number. Three are proven wrong (`chore/srql-test-failing` is PR 3033 not 3036;
      `update/dockerfile_rbe_debian` is 1984 not 1986; `update/sweep-group-bug` is 2361 not 2372).
      Those three are still safe to delete, but their PR provenance in the dataset must not be cited.
- [x] 4.3 No protected-branch rule existed; `main` fell into the delete pool and `staging` was
      spared only incidentally because it is checked out.

## 5. Recover the keepers

Awaiting owner decision on which become GitHub issues.

- [x] 5.1 Open a GitHub issue per approved keeper — #3848 (mDNS add-on), #3849 (retired host), #3850 (SRQL rollups)
- [x] 5.2 Record the issue number in the register below
- [ ] 5.3 Cut a branch off current `staging` per issue and port the work forward (these are weeks
      to months behind — expect a port, not a merge)
- [ ] 5.4 Land each through the normal PR flow

## 6. Retire the discards (BLOCKED on §3)

- [ ] 6.1 Confirm the restore manifest covers every branch about to be deleted
- [ ] 6.2 **Decide the fate of `refs/archive/jj-keep/*` FIRST** — convert the archive-only tips to
      named tags and/or push them, before any deletion runs
- [ ] 6.3 Handle `demo/prod-release` as delete-then-recreate-from-origin: it is a live operational
      branch driving demo image pins and the local ref is 156 commits behind origin
- [ ] 6.4 Delete in one batch, appending to the existing manifest
- [ ] 6.5 Re-verify post-deletion that every deleted tip is still reachable

## 7. Stop this recurring

- [ ] 7.1 Document that `git branch --merged` is unsafe in a squash-merge repo
- [ ] 7.2 Add a protected-branch rule (`staging`, `main`, `demo/prod-release`) to any future sweep

## Keeper register

**Work that exists nowhere else — candidates for GitHub issues:**

| Branch | Tip | What it is | Verdict | GH issue |
| --- | --- | --- | --- | --- |
| `feature/mdns-collector` | `33c3f362` | Complete mDNS discovery collector: `pkg/agent/mdns/*` + tests, `proto/mdns/mdns.proto`, Elixir processor, CNPG migration, full OpenSpec change. 3320 insertions. On **0 of 930** remote tips. PR #2714 closed with no explanation. **Owner direction: must ship as a native add-on attached to an agent (`addons/mdns-discovery`, `supervision: agent-sidecar`), NOT the branch's in-agent `pkg/agent/mdns/*`. This is a redesign, not a port.** | KEEP | **#3848** |
| `docs/github-collaboration-host` | — | Now **more correct than staging**: `README.md:94`, `INSTALL.md:10`, `README-Docker.md:50,291,292` still point users at the retired `code.carverauto.dev`. PR #3763 closed, no successor. Independently confirmed 37 files carried the retired host; 11 references across 12 files were actionable, the other 26 are historical records, load-bearing test fixtures, or repos that never moved. | **DONE** | **#3849** → PR #3852, merged 2026-08-22 |
| `web/elixir_phoenix_poc` | `0de0e6b9` | ~1000 LOC never landed: `rust/srql/src/query/{logs_hourly_stats,otel_metrics_hourly_stats,viz}.rs` + 2 migrations. Caveat: its `rust/srql/migrations/` approach now violates the Elixir-migrations-only rule. | KEEP (port) | **#3850** |
| `updates/observability_srql_fixes` | `d041ca73` | Rebased duplicate of the same rollup work under a better name. Keep this **or** the row above, not both. | KEEP (pick one) | **#3850** |
| `update/gleam_poller_poc` | — | 11 commits / 7402 insertions Gleam BEAM-migration PoC + PRD. `gleam/` never existed on staging. Rejected by direction (Elixir won) — design artifact only. | KEEP as reference | _pending_ |
| `feat/device-detail-ansible-runs` | `22aa337d` | 3 OpenSpec files, 68 insertions (`add-device-detail-ansible-panel`). Likely obsolete — the Ansible LiveViews shipped. | LOW value | _pending_ |
| `bug/sweep_results_missing_armis` | `bd6bc1dd` | Orphan `pkg/{core/services.go,poller/results_poller.go,sync/service.go}`, plus ~350 MB of committed Mach-O binaries and 61 `tls/demo-staging/` files including cert bundle tarballs. **Deliberately NOT filed as a public issue — see §3.5.** | **CLOSED — deleted 2026-08-21** (owner: stale). Archive ref, manifest and delta bundle all still hold `bd6bc1dd`. | n/a (private) |

**Hold, do not delete (usp lane — owned by another agent):**

| Branch | Why |
| --- | --- |
| `usp-41-bounds-impl` | HARD KEEP — zero archive coverage; now tagged `preserve/usp-41-bounds-impl` |
| `usp-39-family-contract` | SOFT KEEP — only readable marker for the 1.5-g payload-family boundary |
| `rescue/usp13-clean-full-stack-20260725` | SOFT KEEP — 0 unique paths, but snapshots a lineage still moving 2026-08-21 |
| `rescue/usp13-v2-wip-20260725` | SOFT KEEP — same |
| `rescue/proposal-alt-4717-20260725` | SOFT KEEP — same; named for Forgejo PR #4717 which `gh` cannot resolve post-migration |

**Already protected:** `staging`, `release/v1.4.41`, `usp-01-proposal` (worktrees); 10 open-PR
branches (#3592, #3593, #3595, #3596, #3598, #3599, #3600, #3601, #3602, #3603); `main`.

**Advisory (safe to delete, glance first):** `preserve/main-wc-20260819`,
`codex/preserve-dirty-main-20260817` (preservation snapshots whose payload is the name),
`fix/recover-seasonal-profile-state` (5 unpushed commits; origin carries the same subjects
under rebased shas).
