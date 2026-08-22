# Change: Triage the 539 surviving local branches and recover the work worth keeping

## Why

A branch sweep on 2026-08-21 deleted 519 local branches, each verified merged into
`github/staging` by ancestry, and recorded them in
`serviceradar-stale-branches-20260821.txt`. That sweep was correct but incomplete,
because ancestry is the wrong test for this repository:

**ServiceRadar squash-merges.** Only **1 of the 539 surviving branches** is an ancestor of
`origin/staging`. PR #2727 is representative: its merge commit `83d8e5fbd` has a single
parent and the subject `Auth/gateway proxy hardening (#2727)`. `git branch --merged` cannot
see a squash-merge, so every squash-merged branch survived the sweep and is now
indistinguishable from genuinely unmerged work. 74 of the survivors have a MERGED PR.

That leaves a pile nobody can reason about: 539 branches, 484 of them from 2026, spanning
`fix/` (168), `mf/` (47), `usp-` (43), `feat/` (43) and others. Some are finished work that
merged under a different commit, some are abandoned experiments, and some are real work that
was never finished and never landed. The last category is the reason this proposal exists —
it is currently invisible.

There is no data-loss emergency. Every one of the 539 tips is reachable from another ref, so
deleting a branch loses the name, not the commits. But 271 of them are reachable **only**
via `refs/archive/jj-keep/<sha>` — a ref named after the commit sha, left behind by the jj
decommission. That work is recoverable and completely undiscoverable: nobody will ever find
it by browsing.

## What Changes

- Classify all 539 surviving branches into evidence-backed buckets, using PR merge state as
  the primary signal and ancestry only as a secondary one.
- For each bucket, decide **keep** or **discard**, recording the reason.
- For every branch judged worth keeping, open a GitHub issue capturing what the work is, why
  it stalled, and what finishing it requires; then do the work on a branch tied to that issue.
- Record every decision in `tasks.md` so the triage is auditable and resumable.
- Preserve a restore path before any deletion: a name→tip manifest that can recreate any
  branch, since names are the only thing at risk.
- **Out of scope:** `usp-01-proposal` and the `usp-*` stack. Another agent owns that
  workstream. All 44 `usp-*` branches are present on the remote and are not touched here.

## Impact

- Affected specs: none directly. This is a triage and recovery vehicle; work that survives
  triage becomes its own change proposal or issue-scoped fix.
- Affected code: none until a keeper is scheduled. Each keeper gets its own branch and PR.
- Affected process: branch hygiene. The sweep's ancestry test is documented as unsafe for
  this repo so the next cleanup does not repeat it.
