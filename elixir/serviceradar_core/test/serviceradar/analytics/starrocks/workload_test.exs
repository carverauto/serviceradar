defmodule ServiceRadar.Analytics.StarRocks.WorkloadTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Analytics.StarRocks.MySQL
  alias ServiceRadar.Analytics.StarRocks.Workload
  alias ServiceRadar.Analytics.StarRocks.Workload.Pinner

  @moduletag :db_free

  # Answers what ensure/1 asks a warehouse and records every other statement.
  defp warehouse(groups, nodes) do
    parent = self()

    fn
      "SHOW BACKENDS" ->
        {:ok, %{columns: ["BackendId", "Alive", "CpuCores"], rows: []}}

      "SHOW COMPUTE NODES" ->
        {:ok, %{columns: ["ComputeNodeId", "Alive", "CpuCores"], rows: nodes}}

      "SHOW RESOURCE GROUPS ALL" ->
        {:ok, %{columns: ["name", "id"], rows: Enum.map(groups, &[&1, 1])}}

      sql ->
        send(parent, {:ddl, sql})
        {:ok, %{columns: [], rows: []}}
    end
  end

  defp ddl do
    receive do
      {:ddl, sql} -> [sql | ddl()]
    after
      0 -> []
    end
  end

  test "a warehouse without the groups gets both, weighted by its smallest live node" do
    nodes = [[1, "true", "64"], [2, "true", "8"], [3, "false", "2"]]

    assert Workload.ensure(warehouse(["default_wg", "default_mv_wg"], nodes)) == :ok

    assert [interactive, background] = ddl()

    assert interactive ==
             ~s|CREATE RESOURCE GROUP sr_interactive TO (user='sr_interactive') WITH (| <>
               ~s|"cpu_weight" = "8", "mem_limit" = "80%", "concurrency_limit" = "24", | <>
               ~s|"big_query_mem_limit" = "1073741824")|

    assert background ==
             ~s|CREATE RESOURCE GROUP sr_background TO (user='sr_background') WITH (| <>
               ~s|"cpu_weight" = "2", "mem_limit" = "15%", "concurrency_limit" = "8", | <>
               ~s|"big_query_mem_limit" = "536870912")|
  end

  test "existing groups are converged to the shipped limits, never recreated" do
    nodes = [[1, "true", "2"]]

    assert Workload.ensure(warehouse(["sr_interactive", "sr_background"], nodes)) == :ok

    assert [
             ~s|ALTER RESOURCE GROUP sr_interactive WITH ("cpu_weight" = "2", | <> _,
             ~s|ALTER RESOURCE GROUP sr_background WITH ("cpu_weight" = "1", | <> _
           ] = ddl()
  end

  test "without a live node nothing is sent" do
    assert Workload.ensure(warehouse([], [[1, "false", "8"]])) ==
             {:error, :no_live_starrocks_node}

    assert ddl() == []
  end

  describe "pooled sessions" do
    setup do
      previous = Application.get_env(:serviceradar_core, Workload)
      on_exit(fn -> restore(previous) end)
    end

    defp restore(nil), do: Application.delete_env(:serviceradar_core, Workload)
    defp restore(previous), do: Application.put_env(:serviceradar_core, Workload, previous)

    # Runs the pool's after_connect the way DBConnection does, against a
    # recording connection.
    defp connect_statements(result \\ {:ok, %{}}) do
      parent = self()
      {module, function, args} = MySQL.connection_opts([])[:after_connect]

      record = fn :conn, sql ->
        send(parent, {:session, sql})
        result
      end

      assert apply(module, function, [:conn | args] ++ [record]) == :ok

      receive do
        {:session, sql} -> sql
      after
        0 -> flunk("no session statement")
      end
    end

    test "a core node's sessions run in the background group" do
      Application.delete_env(:serviceradar_core, Workload)
      assert connect_statements() == "SET resource_group = 'sr_background'"
    end

    test "a web-ng node's sessions run in the interactive group" do
      Application.put_env(:serviceradar_core, Workload, workload: :interactive)
      assert connect_statements() == "SET resource_group = 'sr_interactive'"
    end

    # A warehouse whose resource groups an operator (or another replica's
    # migrator) creates at some point. It answers SET resource_group the way
    # StarRocks does -- an error until the group exists -- and records the
    # group each session ends up in.
    defp start_groupless_warehouse do
      start_supervised!({Agent, fn -> %{groups: MapSet.new(), sessions: %{}} end})
    end

    defp session_query(warehouse) do
      fn session, "SET resource_group = '" <> quoted ->
        group = String.trim_trailing(quoted, "'")

        Agent.get_and_update(warehouse, fn state ->
          if MapSet.member?(state.groups, group) do
            {{:ok, %{}}, put_in(state, [:sessions, session], group)}
          else
            {{:error, {:starrocks_mysql, "resource group not exists: #{group}"}}, state}
          end
        end)
      end
    end

    defp flush_probes do
      receive do
        {:probed, _} -> flush_probes()
      after
        0 -> :ok
      end
    end

    test "a session opened before its group exists is pinned once the group is created" do
      Application.delete_env(:serviceradar_core, Workload)
      warehouse = start_groupless_warehouse()
      query = session_query(warehouse)
      parent = self()

      # The pool's after_connect, run the way DBConnection runs it -- on the
      # first connect and again on every reconnect.
      {module, function, args} = MySQL.connection_opts([])[:after_connect]
      connect = fn session -> apply(module, function, [session | args] ++ [query]) end

      log =
        capture_log(fn ->
          start_supervised!(
            {Pinner,
             probe_interval_ms: 5,
             probe: fn group ->
               result = Workload.pin(:probed_session, group, query)
               send(parent, {:probed, result})
               result
             end,
             repin: fn ->
               connect.(:pooled_session)
               send(parent, :repinned)
             end}
          )

          assert connect.(:pooled_session) == :ok
          assert_receive {:probed, {:error, _}}
          assert_receive {:probed, {:error, _}}
          assert Agent.get(warehouse, & &1.sessions) == %{}

          Agent.update(warehouse, &%{&1 | groups: MapSet.put(&1.groups, "sr_background")})

          assert_receive :repinned
          # Pinned: the probing stops.
          flush_probes()
          refute_receive {:probed, _}, 50
        end)

      assert Agent.get(warehouse, & &1.sessions[:pooled_session]) == "sr_background"

      assert [_once] =
               Regex.scan(~r/not pinned to resource group sr_background/, log)
    end
  end
end
