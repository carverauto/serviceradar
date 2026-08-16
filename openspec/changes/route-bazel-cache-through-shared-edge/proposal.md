# Change: Route Bazel cache traffic through the shared edge and support host-native integration tests

## Why
The shared cache proxy is now the default cache hop for Bazel remote profiles, but cache transport
and remote execution are still coupled in `build:remote_base`. The legacy local integration shell
wrapper selects that Linux RBE profile whenever a credential file exists, then forces the test
action onto the local host. On macOS this builds a Linux test binary and attempts to execute it on
Darwin. It also violates the repository rule that provisioning and tests remain Bazel targets.

Developers need the same fast Bazel compilation and cache path as CI while the database-facing test
actions stay on their native workstation and use unique disposable databases.

## What Changes
- Keep the public cache proxy as the default remote-cache endpoint inherited by `build:remote_base`,
  while remote execution and BES continue using the upstream BuildBuddy service.
- Factor cache and BES transport into `build:cache_only`, which deliberately selects no remote
  executor, Linux platform, remote toolchain, or Linux-only environment.
- Retire the shell/Make integration wrapper and document the guarded lifecycle as explicit Bazel
  invocations: sweep, prepare, conditional migration, provision, suite, and teardown.
- Add `provision_db_s0` through `provision_db_s7` so a focused run clones only its matching shard
  database; retain the all-shard target for CI.
- Normalize the documented fixture contract around canonical `SRQL_TEST_*` variables, one
  caller-owned numeric run identity, per-shard derivation, TLS server-name verification, and an
  explicit teardown after a red shard.
- Normalize libpq `verify-ca`/`verify-full` only at the Rust lifecycle's `tokio-postgres` parser
  boundary, preserving verified TLS for both Rust and Elixir consumers.
- Keep database-facing TestRunner actions local in both Forgejo and BuildBuddy workflows, keep
  compilation remote/cache-eligible, and make credential-file/teardown cleanup outcome-bearing.
- Forward database and NATS credentials only through explicit test profiles selected by local,
  non-uploaded integration invocations; generic remote unit sweeps receive neither.
- Put the named SRQL fixture suites behind the same explicit shared-fixture compatibility guard
  and caller opt-in as the core integration shards, run them in both workflow systems, and map
  verified libpq SSL modes only at their own `tokio-postgres` parser boundary.
- Make the cancelled-run sweep age each disposable database's own data directory rather than the
  shared `pg_database` catalog file.
- Add hermetic cache-profile/workflow/credential configuration tests and update the affected
  developer runbooks.

## Impact
- Affected specs:
  - `bazel-cache-routing`
- Affected code and operations:
  - `.bazelrc`
  - `rust/integration-db/BUILD.bazel`, lifecycle code, and fixture contract documentation
  - `integration_tests/srql/BUILD.bazel`
  - `integration_tests/srql/tests/support/harness.rs`
  - `elixir/serviceradar_core/test/serviceradar/cluster/database_bootstrap_integration_test.exs`
  - `buildbuddy.yaml` and `buildbuddy_setup_fixture_env.sh`
  - Bazel cache configuration tests
  - `Makefile`
  - Image-publishing entry points and the `demo-local-rollout` skill
  - `.agents/skills/srql-fixtures-db-tests/SKILL.md`
  - `AGENTS.md`
  - `../../notes/archive/bazel-bb-ci.md`
  - `k8s/buildbuddy/README.md`
  - `.forgejo/workflows/elixir-integration-sr-core.yml`
  - `.forgejo/workflows/main.yml` and `scripts/ci/configure-srql-fixture.sh`
