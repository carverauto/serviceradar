# Change: Make product release versions artifact-consistent

## Why

OCI Helm packages `1.4.16`, `1.4.17`, and `1.4.18` were published while the
last corresponding ServiceRadar application release remained `v1.4.15`. Each
package embeds application version and demo image tag `v1.4.15`; it is a
chart-only publication, not a product release. OCI artifact versions are
immutable release identities in practice, so deleting or reusing them would
make caches, locks, provenance, and audit trails disagree. The result is an
unexplained gap in user-visible product versions.

## What Changes

- Make a product release version one immutable identity across its Git tag,
  `VERSION`, Helm `version` and `appVersion`, semantic image tags, OCI Helm
  package, and Forgejo release.
- Make `scripts/cut-release.sh` fail before modifying files when either the
  remote Git tag or the OCI Helm chart version is already occupied or cannot
  be verified.
- Require every release-workflow dispatch to resolve an existing release tag
  reachable from `staging`; remove the manual-dispatch fallback that treats an
  arbitrary checked-out commit as a release source.
- Require the release workflow to verify the tagged commit's version metadata
  before it can publish a chart or other product artifacts.
- Reserve chart publishing credentials for the protected release path. A
  chart-only configuration change must be shipped in a documented product
  release rather than directly consuming a future application version.
- Add release-contract tests and an operator runbook for occupied-version
  recovery. Existing chart-only packages remain immutable audit records and
  are never deleted or reissued.

## Impact

- Affected specs: new `release-artifact-integrity` capability.
- Affected code: `scripts/cut-release.sh`, release source validation helpers,
  `.forgejo/workflows/release.yml`, release-contract tests, Helm release
  publishing documentation, and protected registry credential configuration.
- Operational impact: chart-only packages `1.4.16` through `1.4.18` remain
  historical audit records. Product releases have since advanced through
  `v1.4.22`; future releases cannot bypass the unified release path or reuse an
  occupied Git/OCI version.
