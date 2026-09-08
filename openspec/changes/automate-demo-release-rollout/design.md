## Context

The release finalizer verifies the Forgejo release, container images, Helm chart,
native add-on and Wasm catalogs, signatures, and security bundles before it
force-with-lease advances `demo/prod-release`. The Argo application follows only
that branch, but its synchronization policy is manual. The release gate already
provides the promotion boundary; the remaining manual sync adds delay without
adding artifact validation.

## Goals / Non-Goals

- Goals: deploy every complete production release to demo without an operator
  click; preserve the verified release branch as the only automatic source;
  prevent automatic deletion and unrelated drift correction.
- Non-goals: deploy prereleases or arbitrary staging commits; enable pruning;
  enable self-healing; bypass release artifact validation; automate rollback of
  application data.

## Decisions

### Argo reconciles only the guarded release branch

The release workflow remains responsible for promotion. It advances
`demo/prod-release` only after finalization succeeds. Argo automated sync reacts
to that branch movement and does not select versions independently.

### Automatic sync is deliberately non-destructive

`prune` remains false, so resources absent from a new chart are not deleted.
`selfHeal` remains false, so live-only drift is not continuously overwritten.
`allowEmpty` remains false. A normal release may update managed resources and
run existing migration/credential hooks, but destructive reconciliation still
requires an explicit review.

### The coupling is a tested release contract

The release contract test asserts both sides: complete asset verification and
release finalization precede branch advancement, and the Argo application tracks
that branch with automated, non-pruning, non-self-healing synchronization.

## Risks / Trade-offs

- A bad but fully published release can reach demo automatically. Existing image,
  chart, signature, security, and migration gates reduce that risk; demo remains
  the first formal release environment.
- A chart removal will leave an orphan until explicitly pruned. This is preferred
  to deleting stateful resources automatically.

## Migration Plan

1. Land the Argo policy and contract test.
2. Apply the updated Application declaration once.
3. Verify the current release remains `Synced|Healthy`.
4. Validate the next complete release advances the branch and begins sync without
   an operator command.

Rollback removes the `automated` block and restores operator-triggered sync.
