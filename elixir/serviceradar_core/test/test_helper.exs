# Start required applications for tests without starting the full app
# This allows unit tests to run without requiring a database
Application.ensure_all_started(:telemetry)

if System.get_env("SRQL_TEST_DATABASE_URL") ||
     System.get_env("SERVICERADAR_TEST_DATABASE_URL") ||
     System.get_env("SRQL_TEST_DATABASE_URL_FILE") ||
     System.get_env("SERVICERADAR_TEST_DATABASE_URL_FILE") do
  ExUnit.start(exclude: [:external, :cluster, :large_ingestion, :benchmark])
  ServiceRadar.TestSupport.start_core!(sandbox_owner?: false, sandbox_mode: :manual)
else
  ExUnit.start(exclude: [:integration, :external, :cluster, :large_ingestion, :benchmark])
end

# For integration tests that need the database, use:
# mix test --include integration
#
# And ensure the database is set up first:
# mix ecto.create && mix ecto.migrate
#
# For cluster tests that bring up :peer nodes, use:
# mix test --include cluster
#
# Cluster tests require the test runner to be a distributed node
# (the helper starts one if not already alive) and start the
# serviceradar_core Application on each peer, which transitively
# requires the same dependencies as integration tests.
#
# Large ingestion release-gate tests are excluded by default. Run them explicitly with:
# mix test --include large_ingestion --only large_ingestion
#
# External tests call live third-party APIs and are excluded by default. Run them explicitly with:
# mix test --include external --only <external_tag>
#
# Wall-clock prefix-tag benchmarks are excluded by default (flake under CI load). Run with:
# mix test --include benchmark test/serviceradar/prefix_tags/benchmark_test.exs
#
# NOTE on excluding environment-dependent suites: adding a tag here does NOT keep a module out
# of the integration run. ExUnit runs a test that matches an `include` filter even when it also
# matches an `exclude` one, so `mix test --include integration` re-includes every module tagged
# :integration regardless of its other tags. That is why :external above does not keep
# ServiceRadar.Scans.AdhocScanNatsE2ETest out of the CI run.
#
# A suite that needs environment the run may not have must gate itself with a compile-time
# `@moduletag skip:`, which include/exclude cannot override. See
# test/serviceradar/scans/adhoc_scan_nats_e2e_test.exs and
# test/serviceradar/integrations/armis_dire_e2e_test.exs for the three-state form:
# unconfigured -> skip, partially configured -> fail loudly, fully configured -> run.
