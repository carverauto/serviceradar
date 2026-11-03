defmodule ServiceRadar.NetworkDiscovery.TopologyGraph.DgraphBatchProjectionTest do
  # Request counts at the mapper projection boundary, against a Dgraph that
  # refuses every connection: each request fails at once and is counted by the
  # call telemetry, and the failure must come back to the caller.
  use ExUnit.Case, async: false

  alias ServiceRadar.Dgraph
  alias ServiceRadar.NetworkDiscovery.TopologyGraph

  @call_stop [:serviceradar, :dgraph, :call, :stop]

  setup do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(listener)
    :gen_tcp.close(listener)

    env = Map.new(~w(DGRAPH_URL GRAPH_BACKEND), &{&1, System.get_env(&1)})
    previous_backend = Application.get_env(:serviceradar_core, :graph_backend)
    previous_config = Application.get_env(:serviceradar_core, Dgraph)

    System.put_env("DGRAPH_URL", "dgraph://127.0.0.1:#{port}?sslmode=disable")
    System.delete_env("GRAPH_BACKEND")
    Application.put_env(:serviceradar_core, :graph_backend, :dgraph)
    Application.put_env(:serviceradar_core, Dgraph, item_deadline_ms: 2_000, max_attempts: 1)

    test_pid = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        @call_stop,
        fn _event, _measurements, %{operation: operation}, _ ->
          send(test_pid, {:dgraph_call, operation})
        end,
        nil
      )

    on_exit(fn ->
      :telemetry.detach(handler)
      Enum.each(env, fn {name, value} -> restore_env(name, value) end)
      put_app(:graph_backend, previous_backend)
      put_app(Dgraph, previous_config)
    end)

    :ok
  end

  test "one device's interfaces reach Dgraph in one request, and its failure is returned" do
    device = "sr:switch-#{System.unique_integer([:positive])}.example.com"

    interfaces =
      for index <- 1..200 do
        %{device_id: device, if_name: "eth#{index}", if_index: index}
      end

    assert {:error, _reason} = TopologyGraph.upsert_interfaces(interfaces)
    assert calls() == [:upsert_device_graphs]
  end

  test "a topology report does not make a Dgraph request per link" do
    switch = "sr:switch-#{System.unique_integer([:positive])}.example.com"
    observed = DateTime.utc_now()

    links =
      for index <- 1..50 do
        %{
          local_device_id: switch,
          local_device_ip: "192.0.2.1",
          local_if_name: "eth#{index}",
          local_if_index: index,
          neighbor_device_id: "#{switch}-host#{index}",
          neighbor_port_id: "Gi0/1",
          neighbor_mgmt_addr: "192.0.2.#{index + 1}",
          protocol: "LLDP",
          metadata: %{"confidence_tier" => "high", "confidence_score" => 95},
          timestamp: observed
        }
      end

    # The device and interface request fails, so the edge request never runs.
    assert {:error, _reason} = TopologyGraph.upsert_links(links)
    assert calls() == [:upsert_device_graphs]
  end

  defp calls(acc \\ []) do
    receive do
      {:dgraph_call, operation} -> calls([operation | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp put_app(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp put_app(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
