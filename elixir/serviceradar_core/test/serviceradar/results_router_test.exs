defmodule ServiceRadar.ResultsRouterTest do
  @moduledoc """
  Tests for results ingestion routing in ResultsRouter.

  DB connection's search_path determines the schema.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.ResultsRouter

  defmodule TestIngestor do
    @moduledoc false
    def ingest_updates(updates, opts) do
      send(self(), {:ingest, updates, opts})
      :ok
    end
  end

  defmodule TestSweepIngestor do
    @moduledoc false
    def ingest_results(results, execution_id, opts) do
      send(self(), {:sweep_ingest, results, execution_id, opts})
      {:ok, %{hosts_total: length(results)}}
    end
  end

  defmodule TestSysmonIngestor do
    @moduledoc false
    def ingest(payload, status) do
      send(self(), {:sysmon_ingest, payload, status})
      :ok
    end
  end

  defmodule TestPluginIngestor do
    @moduledoc false
    def ingest(payload, status) do
      send(self(), {:plugin_ingest, payload, status})
      :ok
    end
  end

  setup do
    previous = Application.get_env(:serviceradar_core, :sync_ingestor)
    previous_async = Application.get_env(:serviceradar_core, :sync_ingestor_async)
    previous_sweep = Application.get_env(:serviceradar_core, :sweep_ingestor)
    previous_sysmon = Application.get_env(:serviceradar_core, :sysmon_metrics_ingestor)
    previous_plugin = Application.get_env(:serviceradar_core, :plugin_result_ingestor)
    Application.put_env(:serviceradar_core, :sync_ingestor, TestIngestor)
    Application.put_env(:serviceradar_core, :sync_ingestor_async, false)
    Application.put_env(:serviceradar_core, :sweep_ingestor, TestSweepIngestor)
    Application.put_env(:serviceradar_core, :sysmon_metrics_ingestor, TestSysmonIngestor)
    Application.put_env(:serviceradar_core, :plugin_result_ingestor, TestPluginIngestor)

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:serviceradar_core, :sync_ingestor)
      else
        Application.put_env(:serviceradar_core, :sync_ingestor, previous)
      end

      if is_nil(previous_async) do
        Application.delete_env(:serviceradar_core, :sync_ingestor_async)
      else
        Application.put_env(:serviceradar_core, :sync_ingestor_async, previous_async)
      end

      if is_nil(previous_sweep) do
        Application.delete_env(:serviceradar_core, :sweep_ingestor)
      else
        Application.put_env(:serviceradar_core, :sweep_ingestor, previous_sweep)
      end

      if is_nil(previous_sysmon) do
        Application.delete_env(:serviceradar_core, :sysmon_metrics_ingestor)
      else
        Application.put_env(:serviceradar_core, :sysmon_metrics_ingestor, previous_sysmon)
      end

      if is_nil(previous_plugin) do
        Application.delete_env(:serviceradar_core, :plugin_result_ingestor)
      else
        Application.put_env(:serviceradar_core, :plugin_result_ingestor, previous_plugin)
      end
    end)

    :ok
  end

  test "ingests sync updates" do
    status = %{
      source: "results",
      service_type: "sync",
      message: Jason.encode!([%{"device_id" => "dev-1", "ip" => "10.0.0.1"}])
    }

    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})

    assert_receive {:ingest, updates, opts}
    assert [%{"device_id" => "dev-1", "ip" => "10.0.0.1"}] = updates
    assert Keyword.keyword?(opts)
  end

  test "does not ingest when payload is invalid (not a list)" do
    status = %{
      source: "results",
      service_type: "sync",
      message: Jason.encode!(%{"device_id" => "dev-1"})
    }

    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})
    refute_receive {:ingest, _updates, _opts}
  end

  test "ingests sweep results from summary payload" do
    execution_id = Ash.UUID.generate()
    sweep_group_id = Ash.UUID.generate()
    last_sweep = 1_700_000_000

    payload = %{
      "execution_id" => execution_id,
      "sweep_group_id" => sweep_group_id,
      "last_sweep" => last_sweep,
      "total_hosts" => 50,
      "scanner_stats" => %{"packets_sent" => 100, "packets_recv" => 90},
      "hosts" => [
        %{
          "host" => "192.168.1.10",
          "available" => true,
          "icmp_status" => %{"available" => true, "round_trip" => "1ms"}
        },
        %{
          "host" => "192.168.1.11",
          "available" => false,
          "icmp_status" => %{"available" => false}
        }
      ]
    }

    status = %{
      source: "results",
      service_type: "sweep",
      message: Jason.encode!(payload),
      agent_id: "agent-1",
      chunk_index: 0,
      total_chunks: 4,
      is_final: false
    }

    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})

    assert_receive {:sweep_ingest, results, received_execution_id, opts}
    assert length(results) == 2
    assert is_binary(received_execution_id)
    assert Enum.any?(results, &(&1["host_ip"] == "192.168.1.10"))
    assert Enum.any?(results, &(&1["host_ip"] == "192.168.1.11"))

    assert Enum.all?(
             results,
             &(&1["last_sweep_time"] == DateTime.to_iso8601(DateTime.from_unix!(last_sweep)))
           )

    assert opts[:sweep_group_id] == sweep_group_id
    assert opts[:agent_id] == "agent-1"
    assert opts[:expected_total_hosts] == 50
    assert opts[:scanner_metrics] == %{"packets_sent" => 100, "packets_recv" => 90}
    assert opts[:chunk_index] == 0
    assert opts[:total_chunks] == 4
    assert opts[:is_final] == false
  end

  test "rejects non-summary sweep payloads" do
    execution_id = Ash.UUID.generate()

    payload = [
      %{
        "execution_id" => execution_id,
        "sweep_group_id" => Ash.UUID.generate(),
        "host" => "10.0.0.10",
        "available" => true,
        "portScanResults" => [
          %{"port" => 443, "available" => true, "response_time_ns" => 700_000},
          %{"port" => 8443, "available" => true, "response_time_ns" => 900_000}
        ],
        "last_sweep_time" => "2026-02-11T01:33:00Z"
      }
    ]

    status = %{
      source: "results",
      service_type: "sweep",
      message: Jason.encode!(payload),
      agent_id: "agent-legacy"
    }

    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})
    refute_receive {:sweep_ingest, _results, ^execution_id, _opts}
  end

  test "routes sysmon metrics payloads" do
    payload = %{
      "available" => true,
      "response_time" => 123,
      "status" => %{
        "timestamp" => "2025-04-24T14:15:22Z",
        "host_id" => "host-1",
        "host_ip" => "192.168.1.100",
        "cpus" => [],
        "disks" => [],
        "memory" => %{"used_bytes" => 1, "total_bytes" => 2},
        "processes" => []
      }
    }

    status = %{
      source: "sysmon-metrics",
      service_type: "sysmon",
      message: Jason.encode!(payload),
      agent_id: "agent-1",
      gateway_id: "gateway-1"
    }

    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})

    assert_receive {:sysmon_ingest, decoded, ^status}
    assert %{"status" => _} = decoded
  end

  test "routes plugin results payloads" do
    payload = %{
      "status" => "OK",
      "summary" => "plugin ok",
      "perfdata" => "latency=3ms",
      "metrics" => [%{"name" => "latency_ms", "value" => 3, "unit" => "ms"}]
    }

    status = %{
      source: "plugin-result",
      service_type: "plugin",
      message: Jason.encode!(payload),
      agent_id: "agent-1",
      gateway_id: "gateway-1"
    }

    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})

    assert_receive {:plugin_ingest, decoded, ^status}
    assert %{"summary" => "plugin ok"} = decoded
  end
end
