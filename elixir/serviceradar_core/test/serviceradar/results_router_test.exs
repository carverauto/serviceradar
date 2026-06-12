defmodule ServiceRadar.ResultsRouterTest do
  @moduledoc """
  Tests for results ingestion routing in ResultsRouter.

  DB connection's search_path determines the schema.
  """

  use ExUnit.Case, async: false

  alias ServiceRadar.Inventory.EndpointInventoryIngestorQueue
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

  defmodule TestPluginIngestor do
    @moduledoc false
    def ingest(payload, status) do
      send(self(), {:plugin_ingest, payload, status})
      :ok
    end
  end

  defmodule TestEndpointInventoryIngestor do
    @moduledoc false

    def ingest_report(payload, opts) do
      if pid = Application.get_env(:serviceradar_core, :endpoint_inventory_router_test_pid) do
        send(pid, {:endpoint_inventory_ingest, payload, opts})
      end

      {:ok,
       %{
         agent_id: payload["agent_id"],
         scan_id: payload["scan_id"],
         directives: %{"endpoint_inventory" => %{"reconcile_floor" => true}}
       }}
    end
  end

  setup do
    previous = Application.get_env(:serviceradar_core, :sync_ingestor)
    previous_async = Application.get_env(:serviceradar_core, :sync_ingestor_async)
    previous_sweep = Application.get_env(:serviceradar_core, :sweep_ingestor)
    previous_plugin = Application.get_env(:serviceradar_core, :plugin_result_ingestor)
    previous_endpoint = Application.get_env(:serviceradar_core, :endpoint_inventory_ingestor)

    previous_endpoint_async =
      Application.get_env(:serviceradar_core, :endpoint_inventory_ingestor_async)

    previous_endpoint_test_pid =
      Application.get_env(:serviceradar_core, :endpoint_inventory_router_test_pid)

    Application.put_env(:serviceradar_core, :sync_ingestor, TestIngestor)
    Application.put_env(:serviceradar_core, :sync_ingestor_async, false)
    Application.put_env(:serviceradar_core, :sweep_ingestor, TestSweepIngestor)
    Application.put_env(:serviceradar_core, :plugin_result_ingestor, TestPluginIngestor)

    Application.put_env(
      :serviceradar_core,
      :endpoint_inventory_ingestor,
      TestEndpointInventoryIngestor
    )

    Application.put_env(:serviceradar_core, :endpoint_inventory_ingestor_async, false)
    Application.put_env(:serviceradar_core, :endpoint_inventory_router_test_pid, self())

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

      if is_nil(previous_plugin) do
        Application.delete_env(:serviceradar_core, :plugin_result_ingestor)
      else
        Application.put_env(:serviceradar_core, :plugin_result_ingestor, previous_plugin)
      end

      restore_env(:endpoint_inventory_ingestor, previous_endpoint)
      restore_env(:endpoint_inventory_ingestor_async, previous_endpoint_async)
      restore_env(:endpoint_inventory_router_test_pid, previous_endpoint_test_pid)
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

  test "ingests repeated sync result pages independently" do
    first_status = %{
      source: "results",
      service_type: "sync",
      service_name: "sync",
      agent_id: "agent-1",
      gateway_id: "gateway-1",
      partition: "default",
      chunk_index: 0,
      total_chunks: 1,
      is_final: true,
      message:
        Jason.encode!([
          %{
            "device_id" => "default:10.0.0.1",
            "ip" => "10.0.0.1",
            "sync_meta" => %{
              "sync_run_id" => "run-1",
              "chunk_index" => 0,
              "total_chunks" => 1,
              "total_devices" => 2,
              "is_final" => true
            }
          },
          %{
            "device_id" => "default:10.0.0.2",
            "ip" => "10.0.0.2",
            "sync_meta" => %{
              "sync_run_id" => "run-1",
              "chunk_index" => 0,
              "total_chunks" => 1,
              "total_devices" => 2,
              "is_final" => true
            }
          }
        ])
    }

    second_status = %{
      first_status
      | message:
          Jason.encode!([
            %{
              "device_id" => "default:10.0.0.3",
              "ip" => "10.0.0.3",
              "sync_meta" => %{
                "sync_run_id" => "run-1",
                "chunk_index" => 0,
                "total_chunks" => 1,
                "total_devices" => 1,
                "is_final" => true
              }
            }
          ])
    }

    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, first_status}, %{})
    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, second_status}, %{})

    assert_receive {:ingest, first_updates, first_opts}
    assert_receive {:ingest, second_updates, second_opts}

    assert Enum.map(first_updates, & &1["device_id"]) == ["default:10.0.0.1", "default:10.0.0.2"]
    assert Enum.map(second_updates, & &1["device_id"]) == ["default:10.0.0.3"]
    assert Keyword.keyword?(first_opts)
    assert Keyword.keyword?(second_opts)
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
      "banner_grab" => %{
        "sweep_banner_grab_probes_total" => 12,
        "sweep_banner_grab_matches_total" => 5,
        "sweep_banner_grab_empty_response_total" => 2,
        "sweep_banner_grab_errors_total" => 1,
        "sweep_banner_grab_bytes_received_total" => 4096
      },
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
    assert received_execution_id == execution_id
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

    assert opts[:banner_grab_summary] == %{
             "sweep_banner_grab_probes_total" => 12,
             "sweep_banner_grab_matches_total" => 5,
             "sweep_banner_grab_empty_response_total" => 2,
             "sweep_banner_grab_errors_total" => 1,
             "sweep_banner_grab_bytes_received_total" => 4096
           }

    assert opts[:chunk_index] == 0
    assert opts[:total_chunks] == 4
    assert opts[:is_final] == false
  end

  test "derives sweep host availability from successful probes when aggregate is false" do
    execution_id = Ash.UUID.generate()

    payload = %{
      "execution_id" => execution_id,
      "last_sweep" => 1_700_000_000,
      "hosts" => [
        %{
          "host" => "192.168.1.12",
          "available" => false,
          "icmp_status" => %{"available" => false},
          "port_results" => [
            %{"port" => 22, "available" => false, "response_time" => 0},
            %{"port" => 443, "available" => true, "response_time" => "2ms"}
          ]
        }
      ]
    }

    status = %{
      source: "results",
      service_type: "sweep",
      message: Jason.encode!(payload),
      agent_id: "agent-1"
    }

    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})

    assert_receive {:sweep_ingest, [result], _received_execution_id, _opts}
    assert result["host_ip"] == "192.168.1.12"
    assert result["available"] == true
    assert result["icmp_available"] == false

    assert result["port_results"] == [
             %{"port" => 22, "available" => false, "response_time_ns" => 0},
             %{"port" => 443, "available" => true, "response_time_ns" => 2_000_000}
           ]
  end

  test "derives sweep host availability from flattened TCP open ports" do
    execution_id = Ash.UUID.generate()

    payload = %{
      "execution_id" => execution_id,
      "last_sweep" => 1_700_000_000,
      "hosts" => [
        %{
          "host" => "192.168.1.14",
          "available" => false,
          "icmp_status" => %{"available" => false},
          "tcp_ports_open" => [445, "3389", 70_000]
        }
      ]
    }

    status = %{
      source: "results",
      service_type: "sweep",
      message: Jason.encode!(payload),
      agent_id: "agent-1"
    }

    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})

    assert_receive {:sweep_ingest, [result], ^execution_id, _opts}
    assert result["host_ip"] == "192.168.1.14"
    assert result["available"] == true
    assert result["icmp_available"] == false

    assert result["port_results"] == [
             %{"port" => 445, "available" => true, "response_time_ns" => 0},
             %{"port" => 3389, "available" => true, "response_time_ns" => 0}
           ]
  end

  test "does not manufacture ICMP availability for TCP-only sweep results" do
    execution_id = Ash.UUID.generate()

    payload = %{
      "execution_id" => execution_id,
      "last_sweep" => 1_700_000_000,
      "hosts" => [
        %{
          "host" => "192.168.1.13",
          "available" => false,
          "port_results" => [
            %{"port" => 22, "available" => false, "response_time" => 0}
          ]
        }
      ]
    }

    status = %{
      source: "results",
      service_type: "sweep",
      message: Jason.encode!(payload),
      agent_id: "agent-1"
    }

    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})

    assert_receive {:sweep_ingest, [result], ^execution_id, _opts}
    assert result["host_ip"] == "192.168.1.13"
    assert result["available"] == false
    refute Map.has_key?(result, "icmp_available")
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

  test "acknowledges sysmon metrics without direct CNPG ingestion" do
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

    refute_receive {:sysmon_ingest, _decoded, ^status}
  end

  test "acknowledges SNMP metrics without direct CNPG ingestion" do
    status = %{
      source: "snmp-metrics",
      service_type: "snmp",
      message: Jason.encode!(%{"results" => [%{"metric" => "ifHCInOctets", "value" => 1}]}),
      agent_id: "agent-1",
      gateway_id: "gateway-1"
    }

    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})
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

  test "routes asynchronous endpoint inventory payloads through bounded queue" do
    Application.put_env(:serviceradar_core, :endpoint_inventory_ingestor_async, true)
    restart_endpoint_inventory_queue()

    payload = %{"scan_id" => "scan-router-async"}

    status = %{
      source: "results",
      service_type: "endpoint_inventory",
      message: Jason.encode!(payload),
      agent_id: "agent-router-async"
    }

    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})

    expected_payload = Map.put(payload, "agent_id", "agent-router-async")
    assert_receive {:endpoint_inventory_ingest, ^expected_payload, opts}, 500
    assert Keyword.keyword?(opts)
  end

  test "waits for endpoint inventory queue acknowledgement on synchronous status call" do
    Application.put_env(:serviceradar_core, :endpoint_inventory_ingestor_async, true)
    restart_endpoint_inventory_queue()

    payload = %{"scan_id" => "scan-router-sync"}

    status = %{
      source: "results",
      service_type: "endpoint_inventory",
      message: Jason.encode!(payload),
      agent_id: "agent-router-sync"
    }

    assert {:reply,
            {:ok,
             %{
               agent_id: "agent-router-sync",
               scan_id: "scan-router-sync",
               directives: %{"endpoint_inventory" => %{"reconcile_floor" => true}}
             }}, %{}} = ResultsRouter.handle_call({:results_update, status}, self(), %{})

    expected_payload = Map.put(payload, "agent_id", "agent-router-sync")
    assert_receive {:endpoint_inventory_ingest, ^expected_payload, opts}, 500
    assert Keyword.keyword?(opts)
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)

  defp restart_endpoint_inventory_queue do
    restart_task_supervisor(ServiceRadar.EndpointInventoryIngestor.TaskSupervisor)
    stop_process(EndpointInventoryIngestorQueue)

    case start_supervised(EndpointInventoryIngestorQueue) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp restart_task_supervisor(name) do
    stop_process(name)

    case start_supervised({Task.Supervisor, name: name}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp stop_process(name) do
    if pid = Process.whereis(name) do
      ref = Process.monitor(pid)
      Process.exit(pid, :shutdown)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        1_000 -> :ok
      end
    end

    :ok
  end
end
