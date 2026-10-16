defmodule ServiceRadarWebNG.Topology.BitmapRuntimeConfigTest do
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Topology.BitmapQueries
  alias ServiceRadarWebNG.Topology.BitmapSource

  @moduletag :db_free

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
    assert %{key: "tag:zone,group", label: "tag:zone,group", operators: ["eq"]} in descriptor.facets
    assert %{key: "vlan", label: "Inventory VLAN", operators: ["eq"]} in descriptor.facets

    Application.put_env(:serviceradar_web_ng, :god_view_enabled, false)
    refute BitmapQueries.enabled?()

    for value <- [
          "not-json",
          ~s(["role","role"]),
          Jason.encode!(Enum.map(1..26, &("key-" <> Integer.to_string(&1)))),
          Jason.encode!([String.duplicate("x", 61)])
        ] do
      System.put_env("SERVICERADAR_TOPOLOGY_BITMAP_TAG_KEYS", value)

      assert_raise ArgumentError, ~r/SERVICERADAR_TOPOLOGY_BITMAP_TAG_KEYS/, fn ->
        Config.Reader.read!(runtime, env: :test, target: :host)
      end
    end
  end
end
