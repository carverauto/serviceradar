## 1. Catalog selection

- [x] 1.1 Select only the newest import-ready release during unattended sync
- [x] 1.2 Preserve exact historical selection when `release_tag` is supplied
- [x] 1.3 Add unit coverage for newest-release, explicit-release, and partial-release behavior
- [x] 1.4 Anchor scheduled native and Wasm synchronization to the exact deployed release tag even when the recent-release feed omits it

## 2. Immutable anomaly package repair

- [x] 2.1 Bump anomaly add-on manifest and Rust crate from 0.3.0 to 0.3.1
- [x] 2.2 Refresh Cargo lock/vendor inputs required by the native add-on release gate
- [x] 2.3 Verify the anomaly native add-on bundle and version-bump gates

## 3. Validation and rollout

- [x] 3.1 Run web-ng format, compile, strict Credo, and focused native add-on tests
- [x] 3.2 Run strict OpenSpec validation
- [x] 3.3 Publish a feature branch and Forgejo PR linked to issue #4558
- [ ] 3.4 After release, verify demo scheduled sync selects the deployed release and converges without historical conflict retries

## 4. Trusted repair convergence

- [x] 4.1 Reapply auto-approval after verified repair and for reusable allowlisted staged packages
- [x] 4.2 Preserve explicit denied and revoked review decisions during repair
- [x] 4.3 Cover the complete signed first-party demo add-on inventory with the demo trust allowlist
- [ ] 4.4 Verify repaired demo packages approve and their profiles reconcile without operator clicks
- [x] 4.5 Restore non-explicit verified first-party profiles stranded on staged packages to managed rollout when a newer approved package exists
- [x] 4.6 Match catalog entries reused across release-specific OCI envelopes by verified bundle identity
