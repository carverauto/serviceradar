defmodule ServiceRadarWebNG.Topology.BitmapRuntimeConfigTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.Topology.BitmapQueries
  alias ServiceRadarWebNG.Topology.BitmapSource
  alias ServiceRadarWebNG.Topology.WorldCache

  @moduletag :db_free

  @tag timeout: 5_000
  test "an exhausted response deadline admits no query work" do
    keys = [:god_view_enabled, :topology_bitmap_enabled]
    previous = Map.new(keys, &{&1, Application.fetch_env(:serviceradar_web_ng, &1)})
    for key <- keys, do: Application.put_env(:serviceradar_web_ng, key, true)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:serviceradar_web_ng, key, value)
        {key, :error} -> Application.delete_env(:serviceradar_web_ng, key)
      end)
    end)

    start_supervised!(BitmapQueries)
    tasks = start_supervised!({Task.Supervisor, []})
    cache = start_supervised!({WorldCache, task_supervisor: tasks, pubsub: __MODULE__.PubSub})
    :ok = :sys.suspend(cache)
    owner = self()
    started = System.monotonic_time(:millisecond)

    try do
      assert {:error, :query_timeout} =
               BitmapQueries.with_query(
                 %Scope{user: %{id: "synthetic-viewer"}},
                 %{"all" => []},
                 fn _context ->
                   send(owner, {:query_work, self()})
                   WorldCache.world(cache)
                 end,
                 deadline: started - 1
               )

      assert System.monotonic_time(:millisecond) - started < 1_500
      refute_receive {:query_work, _worker}, 50
      assert {:error, :query_timeout} = BitmapQueries.normalize({:error, :deadline_exceeded})
    after
      :sys.resume(cache)
    end
  end

  test "release configuration drives enabled state and the bounded filter-builder allowlist" do
    names = ~w(SERVICERADAR_GOD_VIEW_ENABLED SERVICERADAR_TOPOLOGY_BITMAP_ENABLED SERVICERADAR_TOPOLOGY_BITMAP_TAG_KEYS)
    previous = Map.new(names, &{&1, System.get_env(&1)})
    config_keys = [:god_view_enabled, :topology_bitmap_enabled, :bitmap_tag_keys]
    previous_config = Map.new(config_keys, &{&1, Application.fetch_env(:serviceradar_web_ng, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      Enum.each(previous_config, fn
        {key, :error} -> Application.delete_env(:serviceradar_web_ng, key)
        {key, {:ok, value}} -> Application.put_env(:serviceradar_web_ng, key, value)
      end)
    end)

    Enum.each(names, &System.delete_env/1)
    runtime = Path.expand("../../../config/runtime.exs", __DIR__)
    config = Config.Reader.read!(runtime, env: :test, target: :host)[:serviceradar_web_ng]
    assert config[:topology_bitmap_enabled] == false
    assert config[:bitmap_tag_keys] == []

    System.put_env("SERVICERADAR_GOD_VIEW_ENABLED", "true")
    System.put_env("SERVICERADAR_TOPOLOGY_BITMAP_ENABLED", "true")
    System.put_env("SERVICERADAR_TOPOLOGY_BITMAP_TAG_KEYS", ~s(["role","zone,group"]))
    config = Config.Reader.read!(runtime, env: :test, target: :host)[:serviceradar_web_ng]
    for key <- config_keys, do: Application.put_env(:serviceradar_web_ng, key, config[key])
    assert BitmapQueries.enabled?()
    assert {:ok, descriptor} = BitmapSource.query_descriptor()
    assert descriptor.tag_keys == ["role", "zone,group"]
    assert %{key: "tag:zone,group", label: "tag:zone,group", operators: ["eq", "prefix"]} in descriptor.facets
    assert %{key: "vlan", label: "Inventory VLAN", operators: ["eq", "prefix"]} in descriptor.facets
    assert %{available: false, sources: []} = descriptor.prefix_tags

    Application.put_env(:serviceradar_web_ng, :god_view_enabled, false)
    refute BitmapQueries.enabled?()

    for value <- [
          "not-json",
          ~s("role"),
          ~s(["role","role"]),
          Jason.encode!(Enum.map(1..26, &("key-" <> Integer.to_string(&1)))),
          Jason.encode!([String.duplicate("x", 61)])
        ] do
      System.put_env("SERVICERADAR_TOPOLOGY_BITMAP_TAG_KEYS", value)

      assert_raise ArgumentError, ~r/SERVICERADAR_TOPOLOGY_BITMAP_TAG_KEYS/, fn ->
        Config.Reader.read!(runtime, env: :test, target: :host)
      end
    end

    System.put_env("SERVICERADAR_TOPOLOGY_BITMAP_ENABLED", "false")

    for value <- ["not-json", ~s("role")] do
      System.put_env("SERVICERADAR_TOPOLOGY_BITMAP_TAG_KEYS", value)
      config = Config.Reader.read!(runtime, env: :test, target: :host)[:serviceradar_web_ng]
      assert config[:topology_bitmap_enabled] == false
      assert config[:bitmap_tag_keys] == []
    end
  end
end
