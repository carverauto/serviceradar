# Bazel and BuildBuddy CI notes

## Current build boundary

Bazel builds and tests the Go, Rust, JavaScript, protobuf, Elixir, and OCI-image graphs. Remote
profiles use BuildBuddy for execution and BES. Their cache traffic uses the authenticated public
cache proxy through the shared Envoy edge.

`build:cache_only` owns cache/BES transport without choosing an executor or platform.
`build:remote_base` inherits it and adds the Linux RBE platform, executor, remote toolchain, and
remote-only environment. `build:ci` inherits `build:remote_base`.

That split is load-bearing for database integration tests. A macOS workstation can compile against
the remote cache while producing a Darwin test binary and running `TestRunner` locally. Selecting
`build:ci` there would build a Linux binary and fail when local execution attempts to run it.

## Core integration lifecycle

Forgejo, BuildBuddy workflows, and developers use the same ordered Bazel targets:

```text
//rust/integration-db:sweep_stale_dbs
//rust/integration-db:prepare_template
//elixir/serviceradar_core:migrate_template   (only when pending)
//rust/integration-db:provision_db            (CI/all shards)
//rust/integration-db:provision_db_sN         (focused local shard)
//elixir/serviceradar_core:integration_tests  (or matching integration_tests_sN)
//rust/integration-db:teardown_db
```

All lifecycle targets are deliberately `manual` and guarded by
`--//build:enable_integration_tests`. Test invocations clear `--test_tag_filters`, prepare clears
`--build_tag_filters`, and every database-facing `TestRunner` action stays local to the runner that
can reach CNPG. Compile actions remain eligible for remote cache/RBE according to the selected
profile. Shard runs use `--nocache_test_results` because fixture state is external to the action
graph. Forgejo and BuildBuddy additionally use `--remote_upload_local_results=false` because
compilation is remote there; a cache-only workstation must not use that broad flag or its locally
compiled misses will never populate the shared cache.

Fixture and NATS credentials are opt-in through `test:database_env` / `test:nats_env`. Generic
remote unit tests never receive those values in their action environment. Every DB-facing
invocation selects `--config=database_env` only alongside local TestRunner placement and disabled
test-result upload. The fixture CA is fetched live at job start (cert-manager Secret or
`https://srql-fixture-ca.serviceradar.cloud/ca.crt`); it is not a stored BuildBuddy secret.

The base fixture variables are `SRQL_TEST_DATABASE_URL` and `SRQL_TEST_ADMIN_URL`. The caller sets
one unique numeric `GITHUB_RUN_ID`/`GITHUB_RUN_ATTEMPT` pair for the sequence; Rust and Elixir
derive the same disposable `sr_core_test_<run>_<attempt>[_sN]` database names from them. Never
pre-export the base URL as `SERVICERADAR_TEST_DATABASE_URL`, because that suppresses per-shard
derivation.

For workstation NodePort runs, set both `PGSSLSERVERNAME` and
`SRQL_TEST_DATABASE_SERVER_NAME` to the CNPG certificate's DNS name so the Rust and Elixir clients
verify the same certificate. Locally the caller must invoke teardown after a red shard; Bazel has
no ordered-test or cross-invocation finalizer. Forgejo owns its sequence and uses an `always()`
teardown step; BuildBuddy keeps the sequence in one shell with an EXIT trap that preserves the
primary failure and reports cleanup failure. A stale-database sweep handles cases where no cleanup
can run.

## Credentials

BuildBuddy credentials belong in runner configuration or ignored `.bazelrc.remote` files. Fixture
DSNs come from runner secrets or the credential-only `//:buildbuddy_setup_fixture_env` target,
which also fetches the current fixture CA from the live Secret or the published HTTPS bundle. No
secret value belongs in Bazel flags, source files, logs, or an action uploaded to the public
cache. Do not store `SRQL_TEST_DATABASE_CA_CERT` in the BuildBuddy secret store.
