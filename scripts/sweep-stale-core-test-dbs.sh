#!/usr/bin/env bash
#
# TOMBSTONE -- this script no longer does anything. Delete it after 2026-12-31.
#
# What it did:
#   Dropped leaked `sr_core_test_*` databases from the shared SRQL/CNPG fixture. Runs that
#   were cancelled or whose runner died never reached teardown, so the fixture accumulated
#   per-run databases until someone noticed.
#
# Where the functionality went:
#   //rust/integration-db:sweep_stale_dbs
#   Implementation: rust/integration-db/src/lib.rs, `sweep_stale/1`.
#
#   The whole database lifecycle is Bazel targets now, driven by
#   .forgejo/workflows/elixir-integration-sr-core.yml:
#
#     //rust/integration-db:sweep_stale_dbs    <- replaces THIS script
#     //rust/integration-db:prepare_template
#     //elixir/serviceradar_core:migrate_template
#     //rust/integration-db:provision_db       <- replaces scripts/reset-test-db.sh
#     //elixir/serviceradar_core:integration_tests
#     //rust/integration-db:teardown_db        <- replaces scripts/drop-test-db.sh
#
# Why it is a stub rather than already deleted:
#   Kept briefly so anyone with the old path in a runbook, a local alias or an in-flight
#   branch gets this note instead of "command not found".

set -euo pipefail

cat >&2 <<'EOF'
scripts/sweep-stale-core-test-dbs.sh has been removed.

Use the Bazel target instead:

    bazel test //rust/integration-db:sweep_stale_dbs

It needs SRQL_TEST_ADMIN_URL in the environment, which .bazelrc forwards via --test_env.
EOF

exit 1
