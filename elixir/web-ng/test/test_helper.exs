alias Ecto.Adapters.SQL

# ExUnit's default `assert_receive` deadline is 100ms. That is not a valid
# budget here: with ~1120 tests running across `max_cases` concurrent async
# modules, the VM routinely deschedules a process for far longer. Measured in
# this suite, a bare `start_supervised!/1` took 105ms to return and a
# process-to-process round trip took 515ms, while the same code in isolation
# completes in microseconds.
#
# Tests that wait on another process were therefore asserting a latency the
# environment does not provide -- FirehoseReplayTest failed this way in roughly
# half of all runs. Raising the deadline costs nothing on a green run, because
# `assert_receive` returns the moment the message lands; the timeout is only
# the bound for reporting a genuine failure. `refute_receive` is unaffected: it
# reads `refute_receive_timeout`, which stays at 100ms so negative assertions
# stay fast.
ExUnit.start(assert_receive_timeout: 2_000)

# Test suite should exercise app behavior, not startup migration gating.
if System.get_env("SERVICERADAR_MIGRATIONS_GATE") in [nil, ""] do
  System.put_env("SERVICERADAR_MIGRATIONS_GATE", "false")
end

require_db_tests? = System.get_env("SERVICERADAR_REQUIRE_DB_TESTS") in ["1", "true", "TRUE"]
allow_db_free_tests? = System.get_env("SERVICERADAR_ALLOW_DB_FREE_TESTS") in ["1", "true", "TRUE"]
ci? = System.get_env("CI") in ["1", "true", "TRUE"]
db_required? = require_db_tests? or ci? or not allow_db_free_tests?

if allow_db_free_tests? and not db_required? do
  ExUnit.configure(exclude: [:test], include: [:db_free])

  # A target that runs zero tests must not report success.
  #
  # The filter above is an ALLOW-LIST: every test is excluded and only `:db_free`
  # is re-included. A file without that tag is still LOADED by the shard -- it
  # appears in the runner's `-r` list -- and then contributes nothing, so the
  # shard passes while covering nothing at all. There is no signal that the file
  # you just wrote will never run.
  #
  # Measured when this was added: //elixir/web-ng:unit_tests_property reported
  # PASSED on "0 tests, 0 failures (11 excluded)", and
  # //elixir/web-ng:unit_tests_integration likewise -- both green for as long as
  # they have existed. rules_elixir's own runner tries to assert this
  # (private/ex_unit_test.bzl) but explicitly skips any log containing
  # "excluded", which a default-exclude tier defeats by construction.
  #
  # This catches SHARD-level vacuity only. It does NOT catch a single untagged
  # file in an otherwise-populated shard -- that is a tier-design problem
  # (serviceradar_core defaults to RUNNING via a deny-list; web-ng defaults to
  # silence), and pretending otherwise is how the next person gets caught.
  ExUnit.after_suite(fn %{total: total, excluded: excluded, skipped: skipped} ->
    if total - excluded - skipped == 0 do
      IO.puts(:stderr, """

      FAILED: this target executed ZERO tests (#{total} loaded, #{excluded} excluded, #{skipped} skipped).

      Every test here is excluded unless tagged `@moduletag :db_free`. A target that
      tests nothing must not report success -- add the tag to the files that should
      run without a database, or route them to a DB-backed target.
      """)

      System.at_exit(fn _ -> System.halt(1) end)
    end
  end)
end

if db_required? do
  {:ok, _} = Application.ensure_all_started(:serviceradar_web_ng)
else
  # db_free tests deliberately do not start the application, but the
  # device-detail loaders run their fan-outs under this shared, named
  # Task.Supervisor (see DeviceLive.DeviceTaskData), so it has to exist.
  #
  # Unlinked on purpose: `mix test` keeps the process that runs this file alive
  # for the whole run, but the Bazel ex_unit runner does not, and a linked
  # supervisor died with it -- every fan-out then failed with "no process".
  {:ok, task_supervisor} = Task.Supervisor.start_link(name: ServiceRadarWebNG.TaskSupervisor)
  Process.unlink(task_supervisor)

  # Component tests render `~p` verified routes and vendored static asset paths.
  # Both read the endpoint's :persistent_term entry, so both need a *warmed*
  # endpoint -- and nothing in a db-free run starts the application.
  #
  # Leaving that to the modules themselves is an ordering bug in two directions.
  # Modules that never start it (SettingsComponentsTest, the device-detail
  # provenance tests) only pass when some other module started one first. And a
  # module that starts one from an `async: true` test opens a window for
  # everybody else: Phoenix.Endpoint.Supervisor.start_link/3 passes `name: mod`,
  # so the endpoint's NAME is registered by the supervisor process before its
  # `:warmup` CHILD writes the term. Anything rendering inside that window sees a
  # live endpoint with no term and raises "could not find persistent term for
  # endpoint" -- the flake that hit the wordmark tests at random.
  #
  # Starting (and warming) it once here, before any test module is loaded, closes
  # the window for the whole tier and makes every module's start a no-op.
  # Unlinked for the same reason as the Task.Supervisor above.
  {:ok, endpoint} = ServiceRadarWebNGWeb.Endpoint.start_link([])
  Process.unlink(endpoint)
end

# Use ServiceRadar.Repo from serviceradar_core directly for SQL adapter operations
repo = ServiceRadar.Repo

db_tests_available? =
  cond do
    ci? ->
      true

    not db_required? ->
      false

    true ->
      case SQL.query(repo, "SELECT 1", []) do
        {:ok, _} ->
          true

        {:error, reason} ->
          message = "web-ng test database unavailable: #{inspect(reason)}"

          if require_db_tests? do
            raise message
          else
            IO.warn("Skipping web-ng tests; #{message}")
            System.halt(0)
          end
      end
  end

if db_tests_available? do
  # Create OCSF-aligned device inventory table (OCSF v1.7.0 Device object)
  _ =
    SQL.query!(
      repo,
      """
      CREATE TABLE IF NOT EXISTS ocsf_devices (
        uid text PRIMARY KEY
      )
      """,
      []
    )

  _ =
    Enum.each(
      [
        # OCSF Core Identity
        {"type_id", "integer DEFAULT 0"},
        {"type", "text"},
        {"name", "text"},
        {"hostname", "text"},
        {"ip", "text"},
        {"mac", "text"},
        # OCSF Extended Identity
        {"uid_alt", "text"},
        {"vendor_name", "text"},
        {"model", "text"},
        {"domain", "text"},
        {"zone", "text"},
        {"subnet_uid", "text"},
        {"vlan_uid", "text"},
        {"switch_port_attachment", "jsonb"},
        {"region", "text"},
        # OCSF Temporal
        {"first_seen_time", "timestamptz"},
        {"last_seen_time", "timestamptz"},
        {"created_time", "timestamptz DEFAULT NOW()"},
        {"modified_time", "timestamptz DEFAULT NOW()"},
        # OCSF Risk and Compliance
        {"risk_level_id", "integer"},
        {"risk_level", "text"},
        {"risk_score", "integer"},
        {"is_managed", "boolean"},
        {"is_compliant", "boolean"},
        {"is_trusted", "boolean"},
        {"is_active", "boolean DEFAULT true"},
        # OCSF Nested Objects (JSONB)
        {"os", "jsonb"},
        {"hw_info", "jsonb"},
        {"network_interfaces", "jsonb"},
        {"owner", "jsonb"},
        {"org", "jsonb"},
        {"groups", "jsonb"},
        {"agent_list", "jsonb"},
        # ServiceRadar-specific fields
        {"gateway_id", "text"},
        {"agent_id", "text"},
        {"availability_source_agent_id", "text"},
        {"management_device_id", "text"},
        {"discovery_sources", "text[]"},
        {"is_available", "boolean"},
        {"metadata", "jsonb"}
      ],
      fn {col, type} ->
        SQL.query!(
          repo,
          "ALTER TABLE ocsf_devices ADD COLUMN IF NOT EXISTS #{col} #{type}",
          []
        )
      end
    )

  _ =
    SQL.query!(
      repo,
      """
      CREATE TABLE IF NOT EXISTS gateways (
        gateway_id text PRIMARY KEY
      )
      """,
      []
    )

  _ =
    Enum.each(
      [
        {"component_id", "text"},
        {"registration_source", "text"},
        {"status", "text"},
        {"spiffe_identity", "text"},
        {"first_registered", "timestamptz"},
        {"first_seen", "timestamptz"},
        {"last_seen", "timestamptz"},
        {"metadata", "jsonb"},
        {"created_by", "text"},
        {"is_healthy", "boolean"},
        {"agent_count", "integer"},
        {"checker_count", "integer"},
        {"updated_at", "timestamptz"},
        {"partition_id", "uuid"}
      ],
      fn {col, type} ->
        SQL.query!(
          repo,
          "ALTER TABLE gateways ADD COLUMN IF NOT EXISTS #{col} #{type}",
          []
        )
      end
    )

  _ =
    SQL.query!(
      repo,
      """
      CREATE TABLE IF NOT EXISTS northbound_action_event_handlers (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        name text NOT NULL,
        description text,
        state text NOT NULL DEFAULT 'disabled',
        descriptor_id uuid NOT NULL,
        match_expression jsonb NOT NULL DEFAULT '{}'::jsonb,
        target_resolver jsonb NOT NULL DEFAULT '{}'::jsonb,
        input_template jsonb NOT NULL DEFAULT '{}'::jsonb,
        dedupe_key_template text,
        cooldown_seconds integer NOT NULL DEFAULT 300,
        rate_limit jsonb NOT NULL DEFAULT '{}'::jsonb,
        approval_mode text NOT NULL DEFAULT 'manual',
        service_principal text NOT NULL DEFAULT 'northbound-event-handler',
        last_triggered_at timestamptz,
        metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
        inserted_at timestamptz NOT NULL DEFAULT now(),
        updated_at timestamptz NOT NULL DEFAULT now()
      )
      """,
      []
    )

  # Create logs table for SRQL UUID parameter testing
  _ =
    SQL.query!(
      repo,
      """
      CREATE TABLE IF NOT EXISTS logs (
        timestamp TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        observed_timestamp TIMESTAMPTZ,
        id UUID NOT NULL DEFAULT gen_random_uuid(),
        trace_id TEXT,
        span_id TEXT,
        trace_flags INT,
        severity_text TEXT,
        severity_number INT,
        body TEXT,
        event_name TEXT,
        service_name TEXT,
        service_version TEXT,
        service_instance TEXT,
        scope_name TEXT,
        scope_version TEXT,
        scope_attributes TEXT,
        attributes TEXT,
        resource_attributes TEXT,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
        ingest_identity TEXT NOT NULL DEFAULT '',
        ingest_agent_id TEXT NOT NULL DEFAULT '',
        ingest_partition TEXT NOT NULL DEFAULT '',
        source_ip TEXT,
        PRIMARY KEY (timestamp, id)
      )
      """,
      []
    )

  # Older test databases may have a logs table predating the ingest
  # attribution columns; align them with the migration contract.
  _ =
    SQL.query!(
      repo,
      """
      ALTER TABLE logs
        ADD COLUMN IF NOT EXISTS ingest_identity TEXT NOT NULL DEFAULT '',
        ADD COLUMN IF NOT EXISTS ingest_agent_id TEXT NOT NULL DEFAULT '',
        ADD COLUMN IF NOT EXISTS ingest_partition TEXT NOT NULL DEFAULT ''
      """,
      []
    )

  # Ensure RBAC system role profiles exist for tests that depend on them.
  # In test env we keep seeders disabled to avoid async sandbox ownership issues,
  # so we seed once here during boot.
  try do
    ServiceRadar.Identity.RoleProfileSeeder.seed()
  rescue
    e ->
      IO.warn("Failed to seed role profiles: #{Exception.message(e)}")
  end

  Ecto.Adapters.SQL.Sandbox.mode(ServiceRadar.Repo, :manual)
end
