# Start required applications for tests without starting the full app
# This allows unit tests to run without requiring a database
Application.ensure_all_started(:telemetry)

# Opt-in slowest-test report, for profiling an integration lane.
#
# //build:integration_shards.bzl assigns audited async sources to one concurrent BEAM and balances
# audited blockers across serial BEAMs. Bazel cannot infer runtime, so this report can identify
# hotspots within a serial lane, but it is not benchmark or concurrency evidence.
#
# After the canonical fixture lifecycle provisions serial_6:
#
#   bazel test "${TEST_FLAGS[@]}" --test_env=SERVICERADAR_TEST_SLOWEST=15 \
#     --test_output=all //elixir/serviceradar_core:integration_tests_serial_6
#
# This is profiling-only. ExUnit's built-in slowest report enables trace, which forces
# max_cases: 1 and changes test timeouts to :infinity. Integration runs therefore reject the
# report unless their declared cap is already one; timed CI and acceptance runs leave it unset.
slowest =
  case Integer.parse(System.get_env("SERVICERADAR_TEST_SLOWEST") || "") do
    {count, ""} when count > 0 -> [slowest: count]
    _ -> []
  end

# A BLANK value counts as absent. `System.get_env/1` returns "" for a variable that is set
# but empty, and "" is truthy in Elixir, so the plain `a || b || c` this replaced treated
# `FOO=""` as "a database is available" and took the branch below.
#
# That is what makes the database-free tier defensible. //build/elixir_tests.bzl pins these
# four to "" on every unit group precisely so an ambient value cannot reach them -- and
# without blank-means-absent, pinning them is not merely useless, it FORCES the wrong branch.
# Bazel has no way to unset a variable for an action, only to set one, so "" has to be the
# lever.
#
# The failure it prevents: a valueless `--test_env=SERVICERADAR_TEST_DATABASE_URL` used to be
# global, so it copied whatever the developer's shell held. Anyone following the SRQL fixture
# playbook had it exported, which sent the unit sweep down this branch, started the application,
# and killed 13 targets on
# "Oban migrations have not been run. The oban_jobs table does not exist."
database_available? =
  Enum.any?(
    ~w(
      SRQL_TEST_DATABASE_URL
      SERVICERADAR_TEST_DATABASE_URL
      SRQL_TEST_DATABASE_URL_FILE
      SERVICERADAR_TEST_DATABASE_URL_FILE
    ),
    fn name -> String.trim(System.get_env(name) || "") != "" end
  )

if database_available? do
  # SERVICERADAR_ONLY_INTEGRATION runs ONLY what the database-free Bazel job
  # (//elixir/serviceradar_core:unit_tests) does not, instead of re-running the whole suite
  # on top of it. `--include integration` adds to the default set rather than replacing it,
  # which is why the integration job used to repeat all ~2700 unit tests.
  #
  # The complement is exactly the tests that need a running application: :integration, plus
  # :requires_app for the modules that need the app but are not integration tests.
  # The checked-in cap bounds only async modules. Serial modules retain ExUnit's non-overlap
  # barrier inside their shard.
  if System.get_env("SERVICERADAR_ONLY_INTEGRATION") in ["1", "true", "TRUE"] do
    topology = System.get_env("SERVICERADAR_TEST_TOPOLOGY", "focused")
    lane = System.get_env("SERVICERADAR_TEST_LANE", "focused")

    integration_max_cases =
      ServiceRadar.TestSupport.integration_max_cases!(
        System.get_env("SERVICERADAR_INTEGRATION_MAX_CASES"),
        topology,
        lane,
        slowest != []
      )

    selection_formatter =
      case System.get_env("SERVICERADAR_INTEGRATION_SELECTION_OUTPUT") do
        nil ->
          []

        _configured ->
          [
            formatters: [
              ExUnit.CLIFormatter,
              ServiceRadar.IntegrationSelectionFormatter
            ]
          ]
      end

    repo_pool =
      :serviceradar_core
      |> Application.fetch_env!(ServiceRadar.Repo)
      |> Keyword.fetch!(:pool_size)

    ServiceRadar.TestSupport.integration_repo_pool_size!(repo_pool, topology, lane)

    if slowest == [] do
      IO.puts(
        "SERVICERADAR_INTEGRATION_RUNNER topology=#{topology} lane=#{lane} max_cases=#{integration_max_cases} schedulers=#{System.schedulers_online()} repo_pool=#{repo_pool} trace=false timeouts=enabled"
      )
    else
      IO.puts(
        "SERVICERADAR_INTEGRATION_RUNNER topology=#{topology} lane=#{lane} max_cases=1 schedulers=#{System.schedulers_online()} repo_pool=#{repo_pool} trace=true timeouts=infinity profiling_only=true"
      )
    end

    ExUnit.start(
      [
        exclude: [:test, :external, :cluster, :large_ingestion, :benchmark],
        include: [:integration, :requires_app],
        max_cases: integration_max_cases
      ] ++ slowest ++ selection_formatter
    )
  else
    ExUnit.start([exclude: [:external, :cluster, :large_ingestion, :benchmark]] ++ slowest)
  end

  ServiceRadar.TestSupport.start_core!(
    sandbox_owner?: false,
    sandbox_mode: :manual,
    synchronous_audit_writes?: true
  )
else
  # Asking for the integration-only selection without a database is always a mistake, and a
  # silent fallback here is worse than a failure: the run would quietly execute the
  # database-free unit tier instead and report a green integration job that tested none of
  # the integration tests.
  if System.get_env("SERVICERADAR_ONLY_INTEGRATION") in ["1", "true", "TRUE"] do
    raise """
    SERVICERADAR_ONLY_INTEGRATION is set but no test database URL is present.

    Run the guarded Bazel lifecycle documented in
    .agents/skills/srql-fixtures-db-tests/SKILL.md. For one focused Mix test, first create a
    disposable codex_* scratch database on srql-fixtures and use its verify-full URL and CA.
    """
  end

  # Without a database the application is never started, so anything that needs a running
  # ServiceRadar -- the Repo, Horde's ProcessRegistry, the RateLimiter GenServer, Ash's
  # consolidated protocols -- cannot work. Those modules carry `@moduletag :requires_app`
  # (directly, or via ServiceRadar.DataCase) and are excluded here. What remains is the
  # genuine unit tier, which is what the Bazel job //elixir/serviceradar_core:unit_tests
  # runs with no database at all.
  ExUnit.start(
    [
      exclude: [
        :requires_app,
        :integration,
        :external,
        :cluster,
        :large_ingestion,
        :benchmark
      ]
    ] ++ slowest
  )
end

# Run the complete integration suite through the guarded Bazel lifecycle in
# .agents/skills/srql-fixtures-db-tests/SKILL.md. It owns the unique run id, typed srql-fixtures
# endpoint, per-lane disposable clones, and outcome-bearing teardown. Direct Mix execution is only
# for a focused test against a separately created disposable srql-fixtures scratch database; never
# point it at demo, production, or the shared fixture database itself.
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
