## 1. Discovery and design
- [ ] 1.1 Map the exact Bazel dependency path from Rust targets to `openssl-src` and Perl bootstrap.
- [ ] 1.2 Define supported execution environments (local Linux/macOS, CI, remote executor) and Perl availability assumptions.
- [ ] 1.3 Choose default strategy: host Perl first with hermetic fallback, and define control flags.

## 2. Build graph changes
- [ ] 2.1 Update Bazel/module wiring to avoid fetching/building hermetic Perl in default supported environments.
- [ ] 2.2 Keep an explicit opt-in fallback path for hermetic Perl where policy requires fully hermetic toolchains.
- [ ] 2.3 Regenerate lockfiles/metadata (`MODULE.bazel.lock` and any crate-universe outputs) as needed.

## 3. Verification
- [ ] 3.1 Validate representative Rust targets locally with clean-ish caches.
- [ ] 3.2 Validate `bazel test --config=remote //rust/config-bootstrap:config_bootstrap_test` and at least one additional Rust target.
- [ ] 3.3 Measure and record before/after cold build timing deltas for impacted targets.

## 4. Documentation and rollout
- [ ] 4.1 Document the strategy, fallback controls, and troubleshooting in repo docs.
- [ ] 4.2 Document rollback steps to restore hermetic Perl mode if needed.
