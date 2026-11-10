defmodule ServiceRadar.Analytics.StarRocks.NodeMemoryTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks.NodeMemory

  @moduletag :db_free

  @gib 1_073_741_824
  @mib 1_048_576

  # StarRocks' own defaults, all changeable at runtime.
  @defaults %{
    "mem_limit" => {"70%", false},
    "datacache_mem_size" => {"20%", true},
    "update_memory_limit_percent" => {"60", true},
    "lake_metadata_cache_limit" => {"2147483648", true}
  }

  # A warehouse the way the Frontend answers: node listings with MemLimit as
  # the Frontend prints it, and be_configs rows. Every UPDATE is sent to the
  # test process and, when `store` is given, applied to it.
  defp warehouse(backends, compute_nodes, configs, opts \\ []) do
    parent = self()
    store = Keyword.get(opts, :store)
    update = Keyword.get(opts, :update, fn _sql -> {:ok, %{columns: [], rows: []}} end)

    fn
      "SHOW BACKENDS" ->
        {:ok, %{columns: ["BackendId", "IP", "Alive", "MemLimit"], rows: backends}}

      "SHOW COMPUTE NODES" ->
        {:ok, %{columns: ["ComputeNodeId", "IP", "Alive", "MemLimit"], rows: compute_nodes}}

      "SELECT BE_ID, NAME, VALUE, MUTABLE FROM information_schema.be_configs" <> _ ->
        rows =
          for {id, keys} <- if(store, do: Agent.get(store, & &1), else: configs),
              {name, {value, mutable}} <- keys,
              do: [id, name, value, if(mutable, do: 1, else: 0)]

        {:ok, %{columns: ["BE_ID", "NAME", "VALUE", "MUTABLE"], rows: rows}}

      "UPDATE information_schema.be_configs" <> _ = sql ->
        send(parent, {:update, sql})
        if store, do: apply_update(store, sql)
        update.(sql)
    end
  end

  defp apply_update(store, sql) do
    [_, value, name, id] =
      Regex.run(~r/SET VALUE = '([^']*)' WHERE NAME = '([^']*)' AND BE_ID = (\d+)$/, sql)

    Agent.update(store, fn configs ->
      put_in(configs, [String.to_integer(id), name], {value, true})
    end)
  end

  defp updates do
    receive do
      {:update, sql} -> [sql | updates()]
    after
      0 -> []
    end
  end

  defp update(name, value, id),
    do:
      "UPDATE information_schema.be_configs SET VALUE = '#{value}' WHERE NAME = '#{name}' AND BE_ID = #{id}"

  defp states(node), do: Map.new(node.settings, &{&1.name, &1.state})

  test "a shared-data warehouse on StarRocks defaults gets every shipped value, sized per node" do
    compute_nodes = [
      ["101", "cn-0.example.com", "true", "6.300GB"],
      ["102", "cn-1.example.com", "true", "2.520GB"]
    ]

    assert {:ok, [large, small]} =
             NodeMemory.converge(
               warehouse([], compute_nodes, %{101 => @defaults, 102 => @defaults})
             )

    assert Enum.sort(updates()) ==
             Enum.sort([
               update("datacache_mem_size", "10%", 101),
               update("update_memory_limit_percent", "30", 101),
               update("lake_metadata_cache_limit", Integer.to_string(512 * @mib), 101),
               update("datacache_mem_size", "10%", 102),
               update("update_memory_limit_percent", "30", 102),
               update("lake_metadata_cache_limit", Integer.to_string(192 * @mib), 102)
             ])

    for node <- [large, small] do
      assert node.settings |> Enum.map(& &1.state) |> Enum.uniq() == [:applied]
    end
  end

  test "values already in place are left alone, and one the node cannot change at runtime is reported" do
    configs = %{
      101 => %{
        @defaults
        | "datacache_mem_size" => {"10%", true},
          "update_memory_limit_percent" => {"60", false},
          "lake_metadata_cache_limit" => {"536870912", true}
      }
    }

    compute_nodes = [["101", "cn-0.example.com", "true", "6.300GB"]]

    assert {:ok, [node]} = NodeMemory.converge(warehouse([], compute_nodes, configs))

    assert updates() == []

    assert states(node) == %{
             "datacache_mem_size" => :converged,
             "update_memory_limit_percent" => :restart_required,
             "lake_metadata_cache_limit" => :converged
           }

    assert %{status: :warning, warnings: [warning]} =
             NodeMemory.summarize([node], DateTime.utc_now())

    assert warning =~ "update_memory_limit_percent is 60, ServiceRadar ships 30"
  end

  test "shared-nothing backends get no lake metadata cache setting" do
    backends = [["201", "be-0.example.com", "true", "6.300GB"]]

    assert {:ok, [node]} = NodeMemory.converge(warehouse(backends, [], %{201 => @defaults}))

    assert Enum.sort(updates()) ==
             Enum.sort([
               update("datacache_mem_size", "10%", 201),
               update("update_memory_limit_percent", "30", 201)
             ])

    refute Map.has_key?(states(node), "lake_metadata_cache_limit")
  end

  test "the reserve under each node's detected memory is reported, and a small one warned about" do
    backends = [
      ["201", "be-0.example.com", "true", "8.100GB"],
      ["202", "be-1.example.com", "true", "6.300GB"],
      ["203", "be-2.example.com", "true", "7.000GB"]
    ]

    configs = %{
      201 => %{@defaults | "mem_limit" => {"90%", false}},
      202 => %{@defaults | "mem_limit" => {"70%", false}},
      203 => %{@defaults | "mem_limit" => {"7G", false}}
    }

    assert {:ok, [tight, roomy, absolute]} = NodeMemory.converge(warehouse(backends, [], configs))

    # 10 GiB detected: 90% of mem_limit, then StarRocks' own 90%, leaves 1.9 GiB.
    assert %{detected_memory_bytes: 10_737_418_240, reserve: :low} = tight
    assert_in_delta tight.reserve_bytes, 1.9 * @gib, @mib
    assert %{detected_memory_bytes: 10_737_418_240, reserve: :ok} = roomy
    assert_in_delta roomy.reserve_bytes, 3.7 * @gib, @mib
    assert %{detected_memory_bytes: nil, reserve_bytes: nil, reserve: :unknown} = absolute

    assert %{status: :warning, warnings: [warning]} =
             NodeMemory.summarize([tight, roomy, absolute], DateTime.utc_now())

    assert warning =~ "StarRocks backend 201 (be-0.example.com): 1.9 GiB left under 10.0 GiB"
  end

  test "a warehouse user that may not change node configs is reported, not raised" do
    denied = fn _sql ->
      {:error, {:starrocks_mysql, "Access denied; you need the OPERATE privilege"}}
    end

    compute_nodes = [["101", "cn-0.example.com", "true", "6.300GB"]]

    assert {:ok, [node]} =
             NodeMemory.converge(
               warehouse([], compute_nodes, %{101 => @defaults}, update: denied)
             )

    assert node.settings |> Enum.map(& &1.state) |> Enum.uniq() == [:failed]

    assert %{status: :warning, warnings: [_, _, _]} =
             NodeMemory.summarize([node], DateTime.utc_now())

    unreadable = fn _sql -> {:error, {:starrocks_mysql, "Access denied"}} end
    assert NodeMemory.converge(unreadable) == {:error, {:starrocks_mysql, "Access denied"}}
  end

  test "settings a node restart put back to defaults are applied again on the next pass" do
    {:ok, store} = Agent.start_link(fn -> %{101 => @defaults} end)
    compute_nodes = [["101", "cn-0.example.com", "true", "6.300GB"]]
    query = warehouse([], compute_nodes, nil, store: store)

    start_supervised!({NodeMemory, query: query, initial_delay_ms: 0, interval_ms: 20})

    assert eventually(fn -> NodeMemory.health().status == :ok end)
    assert Agent.get(store, & &1[101]["datacache_mem_size"]) == {"10%", true}
    assert [%{settings: [_, _, _]}] = NodeMemory.health().nodes

    # The node restarts and comes back with StarRocks' defaults.
    updates()
    Agent.update(store, fn _configs -> %{101 => @defaults} end)

    assert eventually(fn ->
             Agent.get(store, & &1[101]["datacache_mem_size"]) == {"10%", true}
           end)

    assert update("datacache_mem_size", "10%", 101) in updates()
  end

  defp eventually(check, attempts \\ 100) do
    cond do
      check.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(check, attempts - 1)
    end
  end
end
