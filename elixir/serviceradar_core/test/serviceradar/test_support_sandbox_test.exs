defmodule ServiceRadar.IntegrationRunnerConfigurationTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.TestSupport

  test "integration max cases accepts only the audited runner topology" do
    assert TestSupport.integration_max_cases!("8", "async_serial", "async", false) == 8
    assert TestSupport.integration_max_cases!("1", "async_serial", "async", true) == 1

    for lane <- Enum.map(0..6, &"serial_#{&1}") do
      assert TestSupport.integration_max_cases!("1", "async_serial", lane, false) == 1
      assert TestSupport.integration_max_cases!("1", "async_serial", lane, true) == 1
    end

    assert TestSupport.integration_max_cases!(
             "1",
             "large_ingestion",
             "large_ingestion",
             false
           ) == 1

    assert TestSupport.integration_max_cases!("1", "focused", "focused", false) == 1
  end

  test "integration max cases rejects malformed values" do
    for value <- [nil, "", "two", "0", "-1", "2x"] do
      assert_raise ArgumentError, ~r/SERVICERADAR_INTEGRATION_MAX_CASES.*positive integer/s, fn ->
        TestSupport.integration_max_cases!(value, "focused", "focused", false)
      end
    end
  end

  test "integration max cases rejects unsupported runner combinations" do
    unsupported = [
      {"999", "async_serial", "async", false},
      {"1", "async_serial", "async", false},
      {"8", "async_serial", "serial_0", false},
      {"1", "async_serial", "serial_7", false},
      {"1", "large_ingestion", "async", false},
      {"1", "unknown", "unknown", false}
    ]

    for {value, topology, lane, profiling?} <- unsupported do
      assert_raise ArgumentError, ~r/unsupported integration runner configuration/s, fn ->
        TestSupport.integration_max_cases!(value, topology, lane, profiling?)
      end
    end
  end

  test "integration max cases rejects concurrent slowest profiling with actionable guidance" do
    assert_raise ArgumentError, ~r/SERVICERADAR_TEST_SLOWEST.*max_cases.*1/s, fn ->
      TestSupport.integration_max_cases!("8", "async_serial", "async", true)
    end
  end

  test "integration Repo pool accepts only the audited runner topology" do
    assert TestSupport.integration_repo_pool_size!(12, "async_serial", "async") == 12

    for lane <- Enum.map(0..6, &"serial_#{&1}") do
      assert TestSupport.integration_repo_pool_size!(12, "async_serial", lane) == 12
    end

    assert TestSupport.integration_repo_pool_size!(12, "large_ingestion", "large_ingestion") ==
             12

    assert TestSupport.integration_repo_pool_size!(12, "focused", "focused") == 12
  end

  test "integration Repo pool rejects unsupported sizes and runner combinations" do
    unsupported = [
      {999, "async_serial", "async"},
      {1, "async_serial", "async"},
      {12, "async_serial", "serial_7"},
      {1, "large_ingestion", "large_ingestion"},
      {1, "focused", "focused"},
      {12, "unknown", "unknown"}
    ]

    for {pool_size, topology, lane} <- unsupported do
      assert_raise ArgumentError, ~r/unsupported integration Repo pool configuration/s, fn ->
        TestSupport.integration_repo_pool_size!(pool_size, topology, lane)
      end
    end
  end

  test "sandbox owner queue timeout recognizes Agent.start MatchError" do
    wrapped = %MatchError{
      term:
        {:error, {%DBConnection.ConnectionError{message: "dropped", reason: :queue_timeout}, []}}
    }

    assert TestSupport.sandbox_owner_queue_timeout?(wrapped)

    assert TestSupport.sandbox_owner_queue_timeout?(%DBConnection.ConnectionError{
             message: "dropped",
             reason: :queue_timeout
           })
  end

  test "sandbox owner queue timeout ignores unrelated failures" do
    refute TestSupport.sandbox_owner_queue_timeout?(%MatchError{term: :other})

    refute TestSupport.sandbox_owner_queue_timeout?(%DBConnection.ConnectionError{
             message: "dropped",
             reason: :closed
           })

    refute TestSupport.sandbox_owner_queue_timeout?(%RuntimeError{message: "nope"})
  end
end

defmodule ServiceRadar.TestSupportSandboxTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias ServiceRadar.Observability.EventRule
  alias ServiceRadar.Observability.LogPromotion
  alias ServiceRadar.ProcessRegistry
  alias ServiceRadar.Repo
  alias ServiceRadar.TestSupport

  @moduletag :integration

  # Deadlines that gate on real database work rather than local message passing.
  # Under RBE these tests share one remote Postgres, so a checkout handoff plus a
  # query round-trip can exceed a second while nothing is wrong -- the flake showed
  # the waiter exiting :normal just outside a 1s window. Sized to the 5s guard the
  # holder already uses for "the connection was genuinely never released".
  @db_wait_ms 5_000

  setup_all do
    TestSupport.start_core!(sandbox_owner?: false)

    assert_raise DBConnection.OwnershipError, fn ->
      Repo.query!("SELECT 1")
    end

    :ok
  end

  test "database owner rolls committed-looking state back between test scopes" do
    table = "sandbox_isolation_#{System.unique_integer([:positive])}"
    qualified_table = "platform.#{table}"

    TestSupport.with_repo_owner(%{async: false}, fn ->
      Repo.query!("CREATE TABLE #{qualified_table} (id integer PRIMARY KEY)")
      Repo.query!("INSERT INTO #{qualified_table} (id) VALUES (1)")

      assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM #{qualified_table}")
    end)

    TestSupport.with_repo_owner(%{async: false}, fn ->
      assert %{rows: [[nil]]} =
               Repo.query!("SELECT to_regclass($1::text)", [qualified_table])
    end)
  end

  test "async unboxed mode is rejected before pool mode changes" do
    assert_raise ArgumentError, ~r/async.*unboxed.*serial lane/s, fn ->
      TestSupport.checkout_repo!(%{async: true, sandbox: :unboxed})
    end

    assert_raise DBConnection.OwnershipError, fn -> Repo.query!("SELECT 1") end
  end

  test "async callers cannot start a shared helper owner" do
    assert_raise ArgumentError, ~r/shared owner.*async/s, fn ->
      TestSupport.with_repo_owner(%{async: true}, fn -> flunk("must not run") end)
    end

    assert_raise DBConnection.OwnershipError, fn -> Repo.query!("SELECT 1") end
  end

  test "no-option startup preserves the audit writer setting" do
    previous = Application.fetch_env(:serviceradar_core, :audit_writer_async?)
    Application.put_env(:serviceradar_core, :audit_writer_async?, true)

    on_exit(fn -> restore_env(:audit_writer_async?, previous) end)

    assert :ok = TestSupport.start_core!(sandbox_owner?: false)
    assert Application.fetch_env!(:serviceradar_core, :audit_writer_async?)
  end

  test "explicit startup configures synchronous audit writes" do
    previous = Application.fetch_env(:serviceradar_core, :audit_writer_async?)
    Application.put_env(:serviceradar_core, :audit_writer_async?, true)

    on_exit(fn -> restore_env(:audit_writer_async?, previous) end)

    assert :ok =
             TestSupport.start_core!(
               sandbox_owner?: false,
               synchronous_audit_writes?: true
             )

    refute Application.fetch_env!(:serviceradar_core, :audit_writer_async?)
  end

  test "stopping one non-shared owner leaves the other owner usable" do
    with_probe_table(fn qualified_table ->
      with_owner_runner(fn runner_a, owner_a ->
        with_owner_runner(fn runner_b, _owner_b ->
          assert %{num_rows: 1} =
                   owner_runner_query(runner_a, "INSERT INTO #{qualified_table} (id) VALUES (1)")

          assert %{rows: [[0]]} =
                   owner_runner_query(runner_b, "SELECT count(*) FROM #{qualified_table}")

          stop_owner_runner(runner_a, owner_a)
          assert_owner_stopped(owner_a)

          assert %{num_rows: 1} =
                   owner_runner_query(runner_b, "INSERT INTO #{qualified_table} (id) VALUES (2)")

          assert %{rows: [[1]]} =
                   owner_runner_query(runner_b, "SELECT count(*) FROM #{qualified_table}")
        end)
      end)
    end)
  end

  test "sandbox allowance accepts only successful results" do
    for accepted <- [:ok, {:already, :allowed}] do
      assert :ok = TestSupport.validate_sandbox_allowance!(accepted, self())
    end

    for rejected <- [{:already, :owner}, :not_found, {:unexpected, :shape}] do
      assert_raise ArgumentError, ~r/sandbox.*allow/i, fn ->
        TestSupport.validate_sandbox_allowance!(rejected, self())
      end
    end
  end

  test "async owner bypasses the singleton rollup while a fresh serial owner keeps it enabled" do
    {:ok, sandbox_owner: owner} = TestSupport.checkout_repo!(%{async: true})
    suffix = System.unique_integer([:positive])
    async_type = "sandbox-async-type-#{suffix}"
    async_vendor = "sandbox-async-vendor-#{suffix}"

    assert %{rows: [["on"]]} =
             Repo.query!("SELECT current_setting('platform.skip_inventory_rollup', true)")

    assert %{rows: [[async_total_before]]} =
             Repo.query!(
               "SELECT COALESCE((SELECT value FROM platform.device_inventory_counts WHERE key = 'total'), 0)"
             )

    Repo.query!(
      "INSERT INTO platform.ocsf_devices (uid, type, vendor_name) VALUES ($1, $2, $3)",
      ["sr:sandbox-async-rollup-#{suffix}", async_type, async_vendor]
    )

    assert %{rows: [[^async_total_before]]} =
             Repo.query!(
               "SELECT COALESCE((SELECT value FROM platform.device_inventory_counts WHERE key = 'total'), 0)"
             )

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM platform.device_inventory_type_counts WHERE type = $1",
               [async_type]
             )

    assert %{rows: [[0]]} =
             Repo.query!(
               "SELECT count(*) FROM platform.device_inventory_vendor_counts WHERE vendor_name = $1",
               [async_vendor]
             )

    TestSupport.stop_repo_owner(owner, shared: false)

    TestSupport.with_repo_owner(%{async: false}, fn ->
      serial_type = "sandbox-serial-type-#{suffix}"

      assert %{rows: [[setting]]} =
               Repo.query!("SELECT current_setting('platform.skip_inventory_rollup', true)")

      refute setting == "on"

      assert %{rows: [[serial_total_before]]} =
               Repo.query!(
                 "SELECT COALESCE((SELECT value FROM platform.device_inventory_counts WHERE key = 'total'), 0)"
               )

      Repo.query!(
        "INSERT INTO platform.ocsf_devices (uid, type) VALUES ($1, $2)",
        ["sr:sandbox-serial-rollup-#{suffix}", serial_type]
      )

      assert %{rows: [[serial_total_after]]} =
               Repo.query!(
                 "SELECT COALESCE((SELECT value FROM platform.device_inventory_counts WHERE key = 'total'), 0)"
               )

      assert serial_total_after == serial_total_before + 1

      assert %{rows: [[1]]} =
               Repo.query!(
                 "SELECT count(*) FROM platform.device_inventory_type_counts WHERE type = $1",
                 [serial_type]
               )
    end)
  end

  test "allowed children see a parent transaction while another owner stays isolated" do
    with_probe_table(fn qualified_table ->
      parent_owner = Sandbox.start_owner!(Repo, shared: false)

      try do
        {child, child_ref} =
          spawn_monitor(fn ->
            receive do
              {:count_rows, parent, table} ->
                send(parent, {:child_rows, self(), Repo.query!("SELECT count(*) FROM #{table}")})
            end
          end)

        try do
          assert :ok = TestSupport.allow_sandbox(child)
          assert %{num_rows: 1} = Repo.query!("INSERT INTO #{qualified_table} (id) VALUES (1)")

          send(child, {:count_rows, self(), qualified_table})
          assert_receive {:child_rows, ^child, %{rows: [[1]]}}, 1_000
          assert_receive {:DOWN, ^child_ref, :process, ^child, :normal}, 1_000

          with_owner_runner(fn other_runner, _other_owner ->
            assert %{rows: [[0]]} =
                     owner_runner_query(other_runner, "SELECT count(*) FROM #{qualified_table}")
          end)
        after
          stop_test_process(child)
        end
      after
        TestSupport.stop_repo_owner(parent_owner, shared: false)
      end
    end)
  end

  test "shared owner lets a legitimate caller wait through brief connection contention" do
    TestSupport.with_repo_owner(%{async: false}, fn ->
      parent = self()

      {holder, holder_ref} =
        spawn_monitor(fn ->
          Repo.checkout(fn ->
            send(parent, {:shared_connection_held, self()})

            receive do
              {:release_shared_connection, ^parent} -> :ok
            after
              5_000 -> raise "shared connection was not released"
            end
          end)
        end)

      try do
        assert_receive {:shared_connection_held, ^holder}, @db_wait_ms

        {waiter, waiter_ref} =
          spawn_monitor(fn ->
            send(parent, {:waiting_query_started, self()})
            send(parent, {:waiting_query_result, self(), Repo.query("SELECT 42")})
          end)

        try do
          assert_receive {:waiting_query_started, ^waiter}, 1_000
          await_ownership_proxy_queue!(@db_wait_ms)
          refute_receive {:waiting_query_result, ^waiter, _result}, 0

          queued_at = System.monotonic_time(:millisecond)
          Process.sleep(1_250)
          assert System.monotonic_time(:millisecond) - queued_at >= 1_250
          assert Process.alive?(waiter)

          send(holder, {:release_shared_connection, self()})

          assert_receive {:waiting_query_result, ^waiter, {:ok, %{rows: [[42]]}}}, @db_wait_ms
          assert_receive {:DOWN, ^waiter_ref, :process, ^waiter, :normal}, @db_wait_ms
          assert_receive {:DOWN, ^holder_ref, :process, ^holder, :normal}, @db_wait_ms
        after
          stop_test_process(waiter)
        end
      after
        send(holder, {:release_shared_connection, self()})
        stop_test_process(holder)
      end
    end)
  end

  test "long tests give sandbox rollback bounded teardown headroom" do
    assert TestSupport.sandbox_ownership_timeout(%{timeout: 1_800_000}) == 1_860_000
    assert is_nil(TestSupport.sandbox_ownership_timeout(%{timeout: 120_000}))
    assert is_nil(TestSupport.sandbox_ownership_timeout(%{}))
  end

  test "repository owner teardown drains shards started by log promotion" do
    previous_shards = Application.get_env(:serviceradar_core, :stateful_alert_engine_shards)
    Application.put_env(:serviceradar_core, :stateful_alert_engine_shards, 1)

    on_exit(fn ->
      case previous_shards do
        nil -> Application.delete_env(:serviceradar_core, :stateful_alert_engine_shards)
        value -> Application.put_env(:serviceradar_core, :stateful_alert_engine_shards, value)
      end
    end)

    {engine_pid, monitor_ref} =
      TestSupport.with_repo_owner(%{async: false}, fn ->
        actor = %{id: "system", role: :admin}
        subject = "logs.sandbox-lifecycle.#{System.unique_integer([:positive])}"

        {:ok, _rule} =
          EventRule
          |> Ash.Changeset.for_create(
            :create,
            %{
              name: "sandbox-lifecycle-#{Ash.UUID.generate()}",
              source_type: :log,
              source: %{},
              match: %{"subject_prefix" => subject},
              event: %{"log_name" => "test.sandbox.lifecycle", "alert" => false}
            },
            actor: actor
          )
          |> Ash.create()

        log = %{
          id: Ash.UUID.generate(),
          timestamp: DateTime.utc_now(),
          severity_text: "INFO",
          severity_number: 11,
          body: "sandbox lifecycle probe",
          service_name: "test",
          attributes: %{"serviceradar" => %{"ingest" => %{"subject" => subject}}},
          resource_attributes: %{},
          created_at: DateTime.utc_now()
        }

        assert {:ok, 1} = LogPromotion.promote([log])

        assert [{pid, _metadata}] = ProcessRegistry.lookup(:stateful_alert_engine)
        assert Process.alive?(pid)
        {pid, Process.monitor(pid)}
      end)

    assert_receive {:DOWN, ^monitor_ref, :process, ^engine_pid, _reason}, 1_000
    assert ProcessRegistry.lookup(:stateful_alert_engine) == []
  end

  defp with_probe_table(fun) do
    table = "sandbox_owner_probe_#{System.unique_integer([:positive])}"
    qualified_table = "platform.#{table}"

    TestSupport.checkout_repo!(%{sandbox: :unboxed})
    Repo.query!("CREATE TABLE #{qualified_table} (id integer PRIMARY KEY)")
    Sandbox.mode(Repo, :manual)

    try do
      fun.(qualified_table)
    after
      Sandbox.mode(Repo, :auto)
      Repo.query!("DROP TABLE IF EXISTS #{qualified_table}")
      Sandbox.mode(Repo, :manual)
    end
  end

  defp with_owner_runner(fun) do
    parent = self()

    {runner, ref} =
      spawn_monitor(fn ->
        owner = Sandbox.start_owner!(Repo, shared: false)

        try do
          send(parent, {:owner_runner_started, self(), owner})
          owner_runner_loop(owner)
        after
          TestSupport.stop_repo_owner(owner, shared: false)
        end
      end)

    receive do
      {:owner_runner_started, ^runner, owner} ->
        try do
          fun.(runner, owner)
        after
          stop_owner_runner(runner, owner)
        end

      {:DOWN, ^ref, :process, ^runner, reason} ->
        flunk("sandbox owner runner exited during startup: #{inspect(reason)}")
    after
      1_000 ->
        stop_test_process(runner)
        flunk("sandbox owner runner did not start")
    end
  end

  defp owner_runner_loop(owner) do
    receive do
      {:query, parent, query} ->
        send(parent, {:owner_runner_query_result, self(), Repo.query!(query)})
        owner_runner_loop(owner)

      {:stop, parent} ->
        send(parent, {:owner_runner_stopping, self(), owner})
        :ok
    end
  end

  defp owner_runner_query(runner, query) do
    send(runner, {:query, self(), query})
    assert_receive {:owner_runner_query_result, ^runner, result}, 1_000
    result
  end

  defp stop_owner_runner(runner, owner) do
    ref = Process.monitor(runner)
    send(runner, {:stop, self()})

    receive do
      {:owner_runner_stopping, ^runner, ^owner} ->
        assert_receive {:DOWN, ^ref, :process, ^runner, :normal}, 1_000

      {:DOWN, ^ref, :process, ^runner, _reason} ->
        :ok
    after
      1_000 ->
        TestSupport.stop_repo_owner(owner, shared: false)
        stop_test_process(runner)
    end

    TestSupport.stop_repo_owner(owner, shared: false)
    assert_owner_stopped(owner)
  end

  defp assert_owner_stopped(owner) do
    ref = Process.monitor(owner)
    assert_receive {:DOWN, ^ref, :process, ^owner, _reason}, 1_000
  end

  defp await_ownership_proxy_queue!(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_ownership_proxy_queue(deadline)
  end

  defp do_await_ownership_proxy_queue(deadline) do
    %{pid: ownership_pool} = Ecto.Adapter.lookup_meta(Repo.get_dynamic_repo())

    queued? =
      ownership_pool
      |> DBConnection.get_connection_metrics(pool: DBConnection.Ownership)
      |> Enum.any?(fn
        %{source: {:proxy, _pid}, checkout_queue_length: length} when length > 0 -> true
        _metric -> false
      end)

    cond do
      queued? ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("waiting query did not enter the ownership proxy queue")

      true ->
        receive do
        after
          5 -> do_await_ownership_proxy_queue(deadline)
        end
    end
  end

  defp stop_test_process(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :shutdown)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        :ok
    after
      1_000 ->
        flunk("test-owned process did not stop: #{inspect(pid)}")
    end
  end

  defp restore_env(key, {:ok, value}), do: Application.put_env(:serviceradar_core, key, value)
  defp restore_env(key, :error), do: Application.delete_env(:serviceradar_core, key)
end
