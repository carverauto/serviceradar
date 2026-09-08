## 1. Contract and inputs

- [x] 1.1 Inventory all schema-affecting inputs, baseline consistency rules, and existing template consumers; reconcile with parallelize-core-integration-tests.
- [x] 1.2 Define canonical manifest, compatibility fields, typed generation selection, structured statuses, and fixture resource limits.
- [x] 1.3 Add Bazel manifest target and unit tests for stable ordering, content changes, baseline changes, duplicate versions, missing inputs, and identifier collision rejection.

## 2. Generation lifecycle

- [x] 2.1 Add guarded registry initialization, private candidates, ownership/fencing, publication, and crash recovery.
- [x] 2.2 Wire the manifest and candidate token into the Elixir migrator and database guard.
- [x] 2.3 Verify complete schema history and baseline consistency before publication; prohibit published generation mutation.
- [x] 2.4 Pin generations across preflight/provision and add clone/cleanup coordination with renewable leases.
- [x] 2.5 Implement bounded template cleanup as a Bazel target; retain ordinary teardown and legacy template protections.
- [x] 2.6 Update all BuildBuddy callers and typed configuration without scripts or credential-bearing action inputs.

## 3. Qualification

- [x] 3.1 Reproduce the current divergent-branch contamination with synthetic inputs.
- [x] 3.2 Prove concurrent divergent generations and their clones contain exactly their own schemas, including a staging-equivalent subset.
- [x] 3.3 Prove same-manifest reuse, edited migration invalidation, failed-build nonpublication, stale-builder rejection, and retry recovery.
- [x] 3.4 Test clone/cleanup races, lease renewal/expiry, capacity failure, and protected database rejection.
- [x] 3.5 Diagnose the cold-baseline lock exhaustion and qualify cold generation construction under fixture connection/lock budgets.
- [x] 3.6 Run relevant Bazel unit contracts, required repository checks, and in-cluster ordinary and large-ingestion lifecycles; measure warm migrator skipping.
- [x] 3.7 Document rollout, bounded cleanup, recovery, and rollback; attach evidence to #4277 before closing it.

## Implementation status

Rust generation lifecycle, Elixir construction, exact database authorization,
ordinary reaper protections, guarded synthetic qualification, and the
synchronized workflow caller cutover are complete on this draft branch.

The seven focused Bazel targets passed after the safety review and source freeze:
manifest unit/artifact, Rust lifecycle unit, Elixir builder/guard, Go reaper, and
embedded SQL mirror contracts. The generated artifact is consumed by the Elixir
tests, including a migration-source environment inventory. OpenSpec strict
validation and formatting checks pass.

The frozen-source `make test` rerun passed all 219 Bazel test targets. Rust
Clippy also passed for the integration-db package and all its targets. The first
full run was not green (a subsequently corrected SQL mirror mismatch and a
concurrent-source upload error); the clean rerun supersedes it.

Compile-only validation passed for the Rust subtree and explicitly selected
guarded generation/migrator targets (154 targets). This caught and corrected a
Rust-edition keyword alias in the manual qualification test. No guarded database
target was executed on the workstation.

The deployed ordinary reaper namespace protection was verified before guarded
qualification. In-cluster evidence now covers divergent synthetic generations,
failure recovery and fencing, clone/cleanup and lease races, capacity and
protected-database refusal, cold full replay with migrator startup, identical
manifest warm reuse without migrator startup, the ordinary lifecycle, and the
large-ingestion release gate including its separate cold-baseline path. Observed
connections remained within the declared fixture budget, and every qualified
lifecycle completed its suite, observer, teardown, and lease release.

Rollout, bounded cleanup, recovery, and rollback are documented in
`docs/docs/ci-schema-templates.md`. The external qualification evidence is
attached to #4277. Keep that issue open until the change lands; this task log does
not claim it closed.
