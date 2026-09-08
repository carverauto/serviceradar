# Change: Automate verified demo release rollouts

## Why

The release workflow already advances `demo/prod-release` only after the tagged
release and its complete artifact set verify, but ArgoCD currently stops at an
`OutOfSync` application and requires an operator to trigger every deployment.
That redundant click leaves demo stale and makes a successful product release
look incomplete.

## What Changes

- Enable ArgoCD automated synchronization for the guarded `demo/prod-release`
  source branch.
- Keep pruning and self-healing disabled so release automation cannot delete
  live resources or overwrite unrelated operator drift.
- Retain the existing release publication gate: prereleases, drafts, incomplete
  asset sets, failed signatures, and failed finalization do not advance the
  branch and therefore cannot deploy.
- Add a release contract test that prevents the guarded branch and conservative
  synchronization policy from drifting apart.

## Impact

- Affected specs: `release-artifact-integrity`
- Affected code: `.forgejo/workflows/release.yml`,
  `k8s/argocd/applications/demo-prod.yaml`, release contract tests
- Operational impact: publishing a complete production release automatically
  rolls demo to its immutable semver image tag; deletions and self-healing remain
  explicit operator actions.
