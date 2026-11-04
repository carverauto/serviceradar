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

    previous_url = System.get_env("DGRAPH_URL")
    previous_config = Application.get_env(:serviceradar_core, Dgraph)

    System.put_env("DGRAPH_URL", "dgraph://127.0.0.1:#{port}?sslmode=disable")
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
      restore_env("DGRAPH_URL", previous_url)
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

  test "a report this node already applied is written again, so a value another node changed since is restored" do
    switch = "sr:switch-#{System.unique_integer([:positive])}.example.com"
    report_x = [neighbor_link(switch, "192.0.2.10")]
    report_y = [neighbor_link(switch, "192.0.2.20")]
    dgraph_url = System.get_env("DGRAPH_URL")

    without_dgraph(fn ->
      assert :ok = TopologyGraph.upsert_links(report_x)
      assert :ok = TopologyGraph.upsert_links(report_y)
      assert :ok = TopologyGraph.upsert_links(report_x)
    end)

    System.put_env("DGRAPH_URL", dgraph_url)
    assert calls() == []

    assert {:error, _reason} = TopologyGraph.upsert_links(report_x)
    assert calls() == [:upsert_device_graphs]
  end

  defp neighbor_link(switch, neighbor_ip) do
    %{
      local_device_id: switch,
      local_device_ip: "192.0.2.1",
      local_if_name: "eth1",
      local_if_index: 1,
      neighbor_device_id: "#{switch}-peer",
      neighbor_port_id: "Gi0/1",
      neighbor_mgmt_addr: neighbor_ip,
      protocol: "LLDP",
      metadata: %{"confidence_tier" => "high", "confidence_score" => 95},
      timestamp: DateTime.utc_now()
    }
  end

  defp without_dgraph(fun) do
    env = Map.new(~w(DGRAPH_URL DGRAPH_HOST), &{&1, System.get_env(&1)})
    app = Map.new([:dgraph_url, :dgraph_host], &{&1, Application.get_env(:serviceradar_core, &1)})
    Enum.each(Map.keys(env), &System.delete_env/1)
    Enum.each(Map.keys(app), &Application.delete_env(:serviceradar_core, &1))

    try do
      fun.()
    after
      Enum.each(env, fn {name, value} -> restore_env(name, value) end)
      Enum.each(app, fn {key, value} -> put_app(key, value) end)
    end
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
