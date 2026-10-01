# Change: Isolate CI database templates by schema inputs

## Why

[Issue #4277](https://github.com/carverauto/serviceradar/issues/4277) records an unmerged branch advancing the shared template beyond staging. Subsequent staging runs then fail before tests execute. Comparing migration versions detects the damage but cannot give each checkout its expected schema.

## What Changes

- Replace the mutable singleton with immutable, content-addressed template generations.
- Produce one declared Bazel manifest covering migration paths and bytes, baseline inputs, and the template construction contract; share its identity across Rust and Elixir.
- Build privately, verify, and publish only complete generations. Pin each run to one generation.
- Coordinate creation, cloning, and bounded garbage collection without dropping active generations.
- Qualify isolation with concurrent synthetic divergent migration sets, failed builders, and clone/cleanup races.

## Impact

- Affected capability: integration-test-execution (additive to the pending parallelize-core-integration-tests change).
- Affected code: rust/integration-db, core template preloader/migrator and database guards, Bazel input declarations, typed CI configuration, and BuildBuddy lifecycle callers.
- No application schema or production database changes.
- Existing template remains protected during rollout; new callers never use it as a fallback.
- Cold creation must be qualified before rollout: a recent scratch baseline application failed with PostgreSQL shared-lock exhaustion. This proposal does not assume that failure is resolved by template isolation.
