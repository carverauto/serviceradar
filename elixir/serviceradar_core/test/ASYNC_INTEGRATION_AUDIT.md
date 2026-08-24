# Integration concurrency audit

This file originally recorded the first two-module async experiment. That snapshot has been
superseded by the exhaustive inventory in
`elixir/serviceradar_core/test/INTEGRATION_SOURCE_DISPOSITIONS.tsv`. The TSV records every source
in `ALL_TEST_SRCS`, every selected module's async or serial disposition, and the code evidence for
that decision. `build/integration_test_dispositions.bzl` is its generated projection; the CI
contract requires the two to agree exactly.

## Current topology

- `integration_tests_async` runs all audited async sources in one BEAM with `max_cases: 8`.
- `integration_tests_serial_0` through `integration_tests_serial_6` split the remaining selected
  sources across seven BEAMs, each with `max_cases: 1`.
- Every BEAM receives its own disposable `srql-fixtures` database clone. No lane uses demo,
  production, or the shared fixture database itself.
- Fixed external-resource tests (NetFlow ingestion, ad-hoc scan NATS E2E, and Proxmox smoke) are
  serial and confined together to `serial_0`; they are never distributed across concurrent BEAMs.

`build/integration_shards.bzl` owns these lane names, concurrency caps, and the deterministic
source partition.

## Representative dispositions

The advisory-feed loader, credential-broker grant lifecycle, secret-broker audit, and
`RemoteAccessHostKeys` modules are currently async. Their TSV rows contain the transaction-owner
or explicit-async evidence supporting those decisions.

The credential event writer, ResultsRouter, first-user role assignment, onboarding package
atomicity, remote-access sessions, and composite-check rollup modules remain serial because they
touch application-global state, use unboxed or independent database connections, truncate shared
tables, or reach global workers. The TSV is authoritative for these reasons and for every other
selected module; this document is only an orientation to the final audit.
