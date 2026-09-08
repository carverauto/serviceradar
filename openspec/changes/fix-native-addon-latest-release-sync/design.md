# Design: Latest-release native add-on convergence

## Context

Native add-on discovery intentionally loads multiple Forgejo releases so an
operator can inspect and explicitly import historical versions. The scheduled
worker reused that same collection without selecting a release, so its candidate
set contained every unique `(add-on, version)` across the discovery window.
That made history behave like desired state.

The package importer correctly treats `(add-on id, semantic version)` as an
immutable identity. It may reuse an existing verified package across a different
OCI envelope only when the verified bundle and artifact contracts are identical.
It must not overwrite an occupied version when the bundle digest changes.

## Decisions

- **The newest indexed release is the unattended desired catalog.** Discovery
  ordering is newest first. When no `release_tag` is supplied, candidate
  selection takes the release tag from the first import-ready entry and selects
  only entries from that release. It does not fill missing entries from history;
  omission from the newest release is meaningful.
- **Explicit release requests remain exact.** A manual or repair operation that
  supplies `release_tag` selects only that tag and may intentionally import a
  historical package.
- **Version collisions remain fail-closed.** A verified signature proves who
  published bytes, not that different bytes are safe to substitute under an
  already-audited version. Changed payloads require a version bump.
- **No database rewrite is used to repair anomaly 0.3.0.** Version 0.3.1 is a
  new immutable package; the existing 0.3.0 row remains valid audit history.

## Risks and mitigations

- A partial newest release could omit an add-on that existed historically.
  Unattended sync will not resurrect it; release completeness gates and explicit
  historical repair remain the controls.
- Forgejo release ordering is an external input. Discovery already preserves
  API order, and tests lock the candidate selector to first import-ready release
  order rather than comparing release-tag strings lexically.
- Existing direct assignments do not automatically change merely because a
  package imports. Assignment rollout policy remains owned by
  `add-native-addon-fleet-rollouts`; this change fixes catalog convergence and
  collision handling without bypassing rollout health gates.

## Rollout

1. Ship the candidate selector and anomaly 0.3.1 in the next formal release.
2. Let scheduled sync import the newest release set and auto-approve only the
   configured trusted IDs.
3. Verify the periodic summary contains no historical source conflicts and no
   OCI fetch failures.
4. Verify anomaly 0.3.1 is the latest approved package before its existing
   profile reconciler advances desired assignments.
