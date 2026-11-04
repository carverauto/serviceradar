defmodule ServiceRadarWebNG.SRQL.GraphQueryTest do
  @moduledoc """
  `in:device_graph` and `in:graph` through `ServiceRadarWebNG.SRQL` and the real
  SRQL parser. These entities read Dgraph, not SQL, so they must never reach the
  SQL translator (which refuses them). Every case here is decided before a
  Dgraph connection is attempted; the live reads are covered by
  `rust/dgraph-topology/tests/schema_lifecycle.rs`.
  """
  use ExUnit.Case, async: false

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.SRQL

  @moduletag :db_free

  setup do
    env_url = System.get_env("DGRAPH_URL")
    env_host = System.get_env("DGRAPH_HOST")
    previous_url = Application.get_env(:serviceradar_core, :dgraph_url)
    previous_host = Application.get_env(:serviceradar_core, :dgraph_host)

    System.delete_env("DGRAPH_URL")
    System.delete_env("DGRAPH_HOST")
    Application.delete_env(:serviceradar_core, :dgraph_url)
    Application.delete_env(:serviceradar_core, :dgraph_host)

    on_exit(fn ->
      restore_env("DGRAPH_URL", env_url)
      restore_env("DGRAPH_HOST", env_host)
      restore_app(:dgraph_url, previous_url)
      restore_app(:dgraph_host, previous_host)
    end)

    :ok
  end

  defp viewer, do: %Scope{user: nil, permissions: MapSet.new(["devices.view"])}

  defp run(query), do: SRQL.query(query, %{scope: viewer()})

  test "device_graph and graph read Dgraph and say so when it is not configured" do
    for query <- [
          ~s|in:device_graph device_id:"sr:host01.example.com"|,
          ~s|in:devicegraph device_id:"sr:host01.example.com" include_topology:false|,
          ~s|in:graph dql:'{ q(func: eq(device.id, "sr:host01.example.com")) { device.id } }'|,
          ~s|in:graph_dql dql:'{ q(func: type(Device), first: 1) { device.id } }'|
        ] do
      assert {:error, reason} = run(query), query
      assert is_binary(reason), query
      assert reason =~ ~r/dgraph/i, "#{query}: #{reason}"
      refute reason =~ "is not SQL", "#{query} must not go through the SQL translator"
    end
  end

  test "device_graph rejects ids that cannot be a DQL string literal" do
    for id <- [~S|sr:host01\"x|, ~S|sr:host01\\x|] do
      assert {:error, reason} = run(~s|in:device_graph device_id:"#{id}"|)
      assert reason =~ "device_id", reason
    end
  end

  test "device_graph requires an equality device_id" do
    assert {:error, reason} = run("in:device_graph include_topology:true")
    assert reason =~ "device_id filter is required"

    assert {:error, reason} = run(~s|in:device_graph !device_id:"sr:host01.example.com"|)
    assert reason =~ "only supports equality"
  end

  test "device_graph refuses collector_owned:true rather than returning nothing" do
    assert {:error, reason} =
             run(~s|in:device_graph device_id:"sr:host01.example.com" collector_owned:true|)

    assert reason =~ "collector_owned:true"
  end

  test "graph refuses a mutation before contacting Dgraph" do
    assert {:error, reason} =
             run(~s|in:graph dql:'mutation { set { _:x <dgraph.type> "Device" . } }'|)

    assert reason =~ "refuses mutations"
  end

  test "a caller without the topology view is forbidden" do
    scope = %Scope{user: nil, permissions: MapSet.new([])}

    assert {:error, :forbidden} =
             SRQL.query(~s|in:device_graph device_id:"sr:host01.example.com"|, %{scope: scope})
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp restore_app(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_app(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
