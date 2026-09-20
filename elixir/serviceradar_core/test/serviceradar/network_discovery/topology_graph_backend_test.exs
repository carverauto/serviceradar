defmodule ServiceRadar.NetworkDiscovery.TopologyGraphBackendTest do
  use ExUnit.Case, async: false

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Backend
  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Persist

  @dgraph_url "dgraph://dgraph.example.com:9080?sslmode=disable"

  setup do
    previous_backend = Application.get_env(:serviceradar_core, :graph_backend)
    previous_read = Application.get_env(:serviceradar_core, :graph_read)
    previous_url = Application.get_env(:serviceradar_core, :dgraph_url)
    previous_host = Application.get_env(:serviceradar_core, :dgraph_host)
    env_backend = System.get_env("GRAPH_BACKEND")
    env_read = System.get_env("GRAPH_READ")
    env_url = System.get_env("DGRAPH_URL")
    env_host = System.get_env("DGRAPH_HOST")

    System.delete_env("GRAPH_BACKEND")
    System.delete_env("GRAPH_READ")
    System.delete_env("DGRAPH_URL")
    System.delete_env("DGRAPH_HOST")
    Application.delete_env(:serviceradar_core, :dgraph_url)
    Application.delete_env(:serviceradar_core, :dgraph_host)

    on_exit(fn ->
      restore_env("GRAPH_BACKEND", env_backend)
      restore_env("GRAPH_READ", env_read)
      restore_env("DGRAPH_URL", env_url)
      restore_env("DGRAPH_HOST", env_host)
      put_app(:graph_backend, previous_backend)
      put_app(:graph_read, previous_read)
      put_app(:dgraph_url, previous_url)
      put_app(:dgraph_host, previous_host)
    end)

    :ok
  end

  test "defaults to AGE writes and AGE reads" do
    Application.delete_env(:serviceradar_core, :graph_backend)
    Application.delete_env(:serviceradar_core, :graph_read)

    assert Backend.backend() == :age
    assert Backend.read() == :age
    assert Backend.write_age?()
    refute Backend.write_dgraph?()
    refute Backend.read_dgraph?()
  end

  test "dual writes AGE and Dgraph while reads stay on AGE" do
    Application.put_env(:serviceradar_core, :graph_backend, :dual)
    Application.put_env(:serviceradar_core, :graph_read, :age)
    Application.put_env(:serviceradar_core, :dgraph_url, @dgraph_url)

    assert Backend.write_age?()
    assert Backend.write_dgraph?()
    assert Backend.read_age?()
    refute Backend.read_dgraph?()
  end

  test "dual without a resolvable Dgraph endpoint does not write Dgraph" do
    Application.put_env(:serviceradar_core, :graph_backend, :dual)

    assert Backend.backend() == :dual
    assert Backend.write_age?()
    refute Backend.write_dgraph?()
  end

  test "GRAPH_BACKEND env wins over application env" do
    Application.put_env(:serviceradar_core, :graph_backend, :age)
    Application.put_env(:serviceradar_core, :dgraph_url, @dgraph_url)
    System.put_env("GRAPH_BACKEND", "dgraph")

    assert Backend.backend() == :dgraph
    refute Backend.write_age?()
    assert Backend.write_dgraph?()
  end

  test "dgraph-only skips AGE execute" do
    Application.put_env(:serviceradar_core, :graph_backend, :dgraph)

    assert Persist.execute_age("MERGE (n:Device {id: 'sr:host01.example.com'})") == :ok
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value) when is_binary(value), do: System.put_env(name, value)

  defp put_app(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp put_app(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
