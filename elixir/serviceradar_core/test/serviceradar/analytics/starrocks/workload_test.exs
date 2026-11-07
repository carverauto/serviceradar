defmodule ServiceRadar.Analytics.StarRocks.WorkloadTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.Analytics.StarRocks.MySQL
  alias ServiceRadar.Analytics.StarRocks.Workload

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

    test "a session that cannot be pinned still connects" do
      Application.delete_env(:serviceradar_core, Workload)

      log =
        capture_log(fn ->
          assert connect_statements({:error, :unknown_variable}) ==
                   "SET resource_group = 'sr_background'"
        end)

      assert log =~ "not pinned to resource group sr_background"
    end
  end
end
