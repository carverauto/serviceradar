## 1. Release-source and version guards

- [x] 1.1 Add a shared release metadata validator for tag, `VERSION`, and
  Helm `version`/`appVersion` agreement at the tagged commit.
- [x] 1.2 Make `cut-release.sh` preflight both the remote Git tag and OCI Helm
  chart version, failing closed before it modifies release files.
- [x] 1.3 Make release-workflow manual dispatch require an existing tag and
  remove the arbitrary-HEAD fallback.
- [x] 1.4 Repeat OCI chart occupancy and metadata validation immediately
  before chart publication.

## 2. Authority and operator workflow

- [x] 2.1 Route chart publication through chart-specific protected-environment
  secrets and document the required Harbor and Forgejo policy.
- [x] 2.2 Add a release runbook covering occupied artifact versions and why
  Git-tag deletion does not make an OCI version reusable.
- [ ] 2.3 Configure and verify the documented Harbor ACLs and protected Forgejo
  release-environment secrets in the deployment environment.

## 3. Verification

- [x] 3.1 Extend release-contract tests for missing tags, mismatched source
  metadata, occupied OCI chart versions, and registry-verification failures.
- [x] 3.2 Verify the normal tag-push and manual retry source contracts both
  resolve a tag and gate chart publication on matching source metadata.
- [ ] 3.3 After deployment configuration is complete, exercise a subsequent
  release and manual retry without overwriting an existing chart version.
