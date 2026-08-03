#!/usr/bin/env bash
#
# TOMBSTONE -- this script no longer does anything. Delete it after 2026-12-31.
#
# What it did:
#   A shell test (//scripts:test_integration_database_guard_test) asserting that the
#   integration database helpers refused to point DDL at anything other than a disposable
#   per-run database -- that reset-test-db.sh, drop-test-db.sh and
#   sweep-stale-core-test-dbs.sh all went through scripts/db/test-database-url-guard.sh and
#   rejected names like `serviceradar` or `postgres`.
#
# Where the functionality went:
#   The guard is now a property of the code that does the dropping, not a separate script
#   that checks other scripts:
#
#     rust/integration-db/src/lib.rs  `assert_disposable/1`
#       refuses any database name without the `sr_core_test_` prefix, and is re-applied to
#       every name the sweep's own query returns.
#     rust/integration-db/src/lib.rs  `like_prefix/1`
#       escapes `_` so the sweep's LIKE pattern cannot match wider than it reads.
#     rust/integration-db/src/template.rs  `TEMPLATE_DATABASE`
#       deliberately does NOT carry the disposable prefix, so neither teardown nor the sweep
#       can drop the shared template.
#
#   Covered by unit tests in the same files -- `assert_disposable_rejects_the_shared_fixture`,
#   `like_prefix_escapes_the_underscore_wildcard` and `the_template_is_not_disposable` --
#   which run in an ordinary `bazel test //rust/integration-db:...` with no fixture required.
#
# Why it is a stub rather than already deleted:
#   Kept briefly so anyone with the old path in a runbook or an in-flight branch gets this
#   note instead of "command not found".

set -euo pipefail

cat >&2 <<'EOF'
scripts/test-integration-database-guard.sh has been removed.

The disposable-database guard now lives in //rust/integration-db and is covered by its own
unit tests:

    bazel test //rust/integration-db:serviceradar_integration_db_test
EOF

exit 1
