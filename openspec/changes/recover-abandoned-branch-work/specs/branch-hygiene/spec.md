## ADDED Requirements

### Requirement: Stale-branch identification does not rely on commit ancestry alone
Branch cleanup SHALL classify a branch as merged only when the forge reports its pull request MERGED and that pull request's merge commit is an ancestor of `origin/staging`.
ServiceRadar squash-merges most pull requests, so a merged branch's tip is normally NOT an
ancestor of `origin/staging`. Any cleanup that infers "merged" from ancestry — including
`git branch --merged <ref>` and `git merge-base --is-ancestor` — is unsafe for this
repository and SHALL NOT be used as the deletion test.

#### Scenario: Squash-merged branch is not misread as unmerged
- **GIVEN** a branch whose pull request was squash-merged into `staging`
- **WHEN** the branch is classified for cleanup
- **THEN** it SHALL be reported merged on the strength of the forge merge state and the
  merge commit's presence in `origin/staging`
- **AND** the result SHALL NOT depend on the branch tip being an ancestor of `staging`

#### Scenario: Local commits beyond the merged head are not discarded
- **GIVEN** a branch whose pull request is MERGED
- **AND** the local branch carries commits beyond the head that was merged
- **WHEN** the branch is classified for cleanup
- **THEN** it SHALL be classified as requiring review rather than safe to delete
- **AND** those extra commits SHALL be inspected before any deletion

### Requirement: Branch deletion is reversible by name
A batch branch deletion SHALL be preceded by a manifest recording every branch name and its tip, together with a means of recreating them.
Deleting a branch discards the only human-readable pointer to its commits, even when those
commits stay reachable from another ref.

#### Scenario: Manifest is written before a batch deletion
- **GIVEN** a batch branch deletion is about to run
- **WHEN** the operator starts the deletion
- **THEN** a name-to-tip manifest covering every branch to be deleted SHALL already exist
- **AND** the deletion SHALL NOT proceed if that manifest is missing or incomplete

#### Scenario: A deleted branch is restored from the manifest
- **GIVEN** a branch was deleted in a previous sweep
- **WHEN** an operator needs it back
- **THEN** the manifest SHALL supply the tip required to recreate it under its original name

### Requirement: Work reachable only from archive refs is triaged explicitly
A branch whose tip is reachable from no ref outside `refs/heads` SHALL be triaged to an explicit outcome with a recorded reason.
The jj decommission left commits reachable only from `refs/archive/jj-keep/<sha>` refs, which
are named after commit shas and are therefore undiscoverable by browsing.

#### Scenario: Archive-only branch is triaged
- **GIVEN** a branch whose tip is reachable from no ref outside `refs/heads` and `refs/archive`
- **WHEN** branch triage runs
- **THEN** it SHALL be resolved to an explicit keep or discard outcome with a recorded reason
- **AND** a keep outcome SHALL produce a tracking issue so the work is discoverable by name

#### Scenario: Archive refs are not silently treated as permanent storage
- **GIVEN** cleanup relies on an archive ref as the safety net for deleting a branch
- **WHEN** the triage output is written
- **THEN** that dependency SHALL be recorded
- **AND** retention of the archive refs SHALL be an explicit decision rather than an assumption
