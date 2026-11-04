defmodule ServiceRadar.NetworkDiscovery.TopologyGraphStoreTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias ServiceRadar.NetworkDiscovery.TopologyGraph.Store

  @dgraph_url "dgraph://dgraph.example.com:9080?sslmode=disable"
  @unresolved_url_marker {Store, :dgraph_url_unresolved}

  setup do
    previous_url = Application.get_env(:serviceradar_core, :dgraph_url)
    previous_host = Application.get_env(:serviceradar_core, :dgraph_host)
    env_url = System.get_env("DGRAPH_URL")
    env_host = System.get_env("DGRAPH_HOST")

    System.delete_env("DGRAPH_URL")
    System.delete_env("DGRAPH_HOST")
    Application.delete_env(:serviceradar_core, :dgraph_url)
    Application.delete_env(:serviceradar_core, :dgraph_host)
    :persistent_term.erase(@unresolved_url_marker)

    on_exit(fn ->
      :persistent_term.erase(@unresolved_url_marker)
      restore_env("DGRAPH_URL", env_url)
      restore_env("DGRAPH_HOST", env_host)
      put_app(:dgraph_url, previous_url)
      put_app(:dgraph_host, previous_host)
    end)

    :ok
  end

  test "a resolvable Dgraph endpoint is writable" do
    Application.put_env(:serviceradar_core, :dgraph_url, @dgraph_url)

    assert Store.writable?()
  end

  test "an unconfigured Dgraph reports the dropped writes once per transition" do
    log =
      capture_log(fn ->
        refute Store.writable?()
      end)

    assert log =~ "Dgraph topology graph is not configured"
    assert log =~ "topology writes are being dropped"

    repeat =
      capture_log(fn ->
        refute Store.writable?()
        refute Store.writable?()
      end)

    assert repeat == "", "the drop must be reported per transition, not per write"

    Application.put_env(:serviceradar_core, :dgraph_url, @dgraph_url)

    recovery =
      capture_log(fn ->
        assert Store.writable?()
      end)

    assert recovery =~ "resumed"
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value) when is_binary(value), do: System.put_env(name, value)

  defp put_app(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp put_app(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
