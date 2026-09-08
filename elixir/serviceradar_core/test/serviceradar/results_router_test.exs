defmodule ServiceRadar.ResultsRouterTest do
  @moduledoc """
  Tests for results ingestion routing in ResultsRouter.

  DB connection's search_path determines the schema.
  """

  use ServiceRadar.DataCase, async: false

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

      Application.get_env(
        :serviceradar_core,
        :plugin_result_ingestor_test_result,
        :ok
      )
    end
  end

  defmodule TestEndpointInventoryIngestor do
    @moduledoc false

    def ingest_report(payload, opts) do
      if pid = Application.get_env(:serviceradar_core, :endpoint_inventory_router_test_pid) do
        send(pid, {:endpoint_inventory_ingest, payload, opts})
      end

      await_test_release(payload)

      if pid = Application.get_env(:serviceradar_core, :endpoint_inventory_router_test_pid) do
        send(pid, {:endpoint_inventory_ingest_finished, payload})
      end

      {:ok,
       %{
         agent_id: payload["agent_id"],
         scan_id: payload["scan_id"],
         directives: %{"endpoint_inventory" => %{"reconcile_floor" => true}}
       }}
    end

    defp await_test_release(payload) do
      case Application.get_env(:serviceradar_core, :endpoint_inventory_router_test_barrier) do
        barrier_ref when is_reference(barrier_ref) ->
          test_pid =
            Application.fetch_env!(:serviceradar_core, :endpoint_inventory_router_test_pid)

          send(test_pid, {:endpoint_inventory_ingest_blocked, payload, self(), barrier_ref})

          receive do
            {:release_endpoint_inventory_ingest, ^barrier_ref} -> :ok
          end

        _no_barrier ->
          :ok
      end
    end
  end

  setup do
    previous = Application.get_env(:serviceradar_core, :sync_ingestor)
    previous_async = Application.get_env(:serviceradar_core, :sync_ingestor_async)
    previous_sweep = Application.get_env(:serviceradar_core, :sweep_ingestor)
    previous_plugin = Application.get_env(:serviceradar_core, :plugin_result_ingestor)

    previous_plugin_result =
      Application.get_env(:serviceradar_core, :plugin_result_ingestor_test_result)

    previous_endpoint = Application.get_env(:serviceradar_core, :endpoint_inventory_ingestor)

    previous_endpoint_async =
      Application.get_env(:serviceradar_core, :endpoint_inventory_ingestor_async)

    previous_endpoint_test_pid =
      Application.get_env(:serviceradar_core, :endpoint_inventory_router_test_pid)

    previous_endpoint_test_barrier =
      Application.get_env(:serviceradar_core, :endpoint_inventory_router_test_barrier)

    previous_endpoint_callback =
      Application.get_env(:serviceradar_core, :endpoint_inventory_after_ingest_callback)

    previous_endpoint_queue_server =
      Application.get_env(:serviceradar_core, :endpoint_inventory_ingestor_queue_server)

    previous_batching = Application.get_env(:serviceradar_core, :results_router_batching)
    previous_max_buffer = Application.get_env(:serviceradar_core, :results_router_max_buffer)

    # These tests drive handle_cast/2 directly with a bare %{} state and assert the
    # routed ingestor fires synchronously. Disable async batching so the cast path
    # processes immediately; batching has its own dedicated test ("async batching").
    Application.put_env(:serviceradar_core, :results_router_batching, false)

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

    {:ok, endpoint_inventory_task_supervisor} = start_supervised(Task.Supervisor)

    {:ok, endpoint_inventory_queue} =
      start_supervised(
        {EndpointInventoryIngestorQueue,
         name: nil, task_supervisor: endpoint_inventory_task_supervisor}
      )

    Application.put_env(
      :serviceradar_core,
      :endpoint_inventory_ingestor_queue_server,
      endpoint_inventory_queue
    )

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
      restore_env(:endpoint_inventory_router_test_barrier, previous_endpoint_test_barrier)
      restore_env(:endpoint_inventory_after_ingest_callback, previous_endpoint_callback)
      restore_env(:endpoint_inventory_ingestor_queue_server, previous_endpoint_queue_server)
      restore_env(:results_router_batching, previous_batching)
      restore_env(:results_router_max_buffer, previous_max_buffer)
      restore_env(:plugin_result_ingestor_test_result, previous_plugin_result)
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

  test "routes the netprobe device census into sync ingestion" do
    # A MISSING clause here fails silently: process/2 falls through to the
    # catch-all, returns :ok, and publish_status_update/1 still runs -- so the
    # service reports healthy while its whole payload is discarded with no log
    # line anywhere. Routing has to be asserted, not reviewed.
    status = %{
      source: "results",
      service_type: "netprobe-census",
      message:
        Jason.encode!([
          %{
            "ip" => "192.168.1.10",
            "mac" => "BC:24:11:F5:1C:82",
            "source" => "netprobe-census",
            "metadata" => %{"mac" => "BC:24:11:F5:1C:82"}
          }
        ])
    }

    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})

    assert_receive {:ingest, updates, _opts}
    assert [%{"ip" => "192.168.1.10", "source" => "netprobe-census"}] = updates
  end

  test "routes the legacy passive-census service type the same way" do
    # SourcePolicy accepts both spellings, so routing must too -- otherwise the
    # policy recognises a source that can never reach it.
    status = %{
      source: "results",
      service_type: "passive-census",
      message: Jason.encode!([%{"ip" => "192.168.1.11", "source" => "passive-census"}])
    }

    assert {:noreply, %{}} = ResultsRouter.handle_cast({:results_update, status}, %{})

    assert_receive {:ingest, updates, _opts}
    assert [%{"ip" => "192.168.1.11"}] = updates
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
      "agent_id" => "spoofed-payload-agent",
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
      partition: "payload-target-partition",
      authenticated_partition: "cert-partition",
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
    assert opts[:authenticated_agent_id] == "agent-1"
    assert opts[:authenticated_partition_id] == "cert-partition"
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

  test "rejects direct core routing for sysmon metric statuses" do
    status = %{
      source: "sysmon-metrics",
      service_type: "sysmon",
      message: metric_batch_fixture(),
      agent_id: "agent-1",
      gateway_id: "gateway-1"
    }

    assert {:reply, {:error, {:gateway_metric_status_not_core_routable, "sysmon-metrics"}}, %{}} =
             ResultsRouter.handle_call({:results_update, status}, self(), %{})

    refute_receive {:sysmon_ingest, _decoded, ^status}
  end

  test "rejects direct core routing for SNMP metric statuses" do
    status = %{
      source: "snmp-metrics",
      service_type: "snmp",
      message: metric_batch_fixture(),
      agent_id: "agent-1",
      gateway_id: "gateway-1"
    }

    assert {:reply, {:error, {:gateway_metric_status_not_core_routable, "snmp-metrics"}}, %{}} =
             ResultsRouter.handle_call({:results_update, status}, self(), %{})
  end

  test "rejects direct core routing for ICMP metric statuses" do
    status = %{
      source: "icmp-metrics",
      service_type: "icmp",
      message: metric_batch_fixture(),
      agent_id: "agent-1",
      gateway_id: "gateway-1"
    }

    assert {:reply, {:error, {:gateway_metric_status_not_core_routable, "icmp-metrics"}}, %{}} =
             ResultsRouter.handle_call({:results_update, status}, self(), %{})
  end

  test "rejects direct core routing for rperf metric statuses" do
    status = %{
      source: "rperf-metrics",
      service_type: "rperf",
      message: metric_batch_fixture(),
      agent_id: "agent-1",
      gateway_id: "gateway-1"
    }

    assert {:reply, {:error, {:gateway_metric_status_not_core_routable, "rperf-metrics"}}, %{}} =
             ResultsRouter.handle_call({:results_update, status}, self(), %{})
  end

  test "routes plugin results payloads" do
    payload = %{
      "status" => "OK",
      "summary" => "plugin ok",
      "perfdata" => "latency=3ms"
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
    refute Map.has_key?(decoded, "metrics")
  end

  test "rejects legacy plugin result metrics instead of sanitizing them" do
    payload = %{
      "status" => "OK",
      "summary" => "plugin ok",
      "metrics" => [%{"name" => "latency_ms", "value" => 3, "unit" => "ms"}]
    }

    status = %{
      source: "plugin-result",
      service_type: "plugin",
      message: Jason.encode!(payload),
      agent_id: "agent-1",
      gateway_id: "gateway-1"
    }

    assert {:reply, {:error, :plugin_result_metrics_unsupported}, %{}} =
             ResultsRouter.handle_call({:results_update, status}, self(), %{})

    refute_receive {:plugin_ingest, _payload, _status}
  end

  test "returns plugin ingestion failures to synchronous callers" do
    error = {:error, {:plugin_result_handlers_failed, [{TestPluginIngestor, "failed"}]}}

    Application.put_env(
      :serviceradar_core,
      :plugin_result_ingestor_test_result,
      error
    )

    payload = %{"status" => "OK", "summary" => "plugin ok"}

    status = %{
      source: "plugin-result",
      service_type: "plugin",
      message: Jason.encode!(payload),
      agent_id: "agent-1",
      gateway_id: "gateway-1"
    }

    assert {:reply, ^error, %{}} =
             ResultsRouter.handle_call({:results_update, status}, self(), %{})

    assert_receive {:plugin_ingest, ^payload, ^status}
  end

  test "routes asynchronous endpoint inventory payloads through bounded queue" do
    Application.put_env(:serviceradar_core, :endpoint_inventory_ingestor_async, true)

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

  test "sync endpoint inventory status calls admit work and reply on ingest completion" do
    Application.put_env(:serviceradar_core, :endpoint_inventory_ingestor_async, true)
    barrier_ref = make_ref()

    Application.put_env(
      :serviceradar_core,
      :endpoint_inventory_router_test_barrier,
      barrier_ref
    )

    payload = %{"scan_id" => "scan-router-sync"}
    reply_ref = make_ref()
    reply_to = {self(), reply_ref}

    status = %{
      source: "results",
      service_type: "endpoint_inventory",
      message: Jason.encode!(payload),
      agent_id: "agent-router-sync"
    }

    assert {:reply, :ok, %{}} =
             ResultsRouter.handle_call(
               {:results_update_async_reply, status, reply_to},
               self(),
               %{}
             )

    expected_payload = Map.put(payload, "agent_id", "agent-router-sync")
    assert_receive {:endpoint_inventory_ingest, ^expected_payload, opts}, 500
    assert Keyword.keyword?(opts)

    assert_receive {:endpoint_inventory_ingest_blocked, ^expected_payload, task_pid,
                    ^barrier_ref},
                   500

    task_monitor = Process.monitor(task_pid)
    refute_received {:endpoint_inventory_ingest_finished, ^expected_payload}
    refute_received {^reply_ref, _reply}
    send(task_pid, {:release_endpoint_inventory_ingest, barrier_ref})

    assert_receive {:endpoint_inventory_ingest_finished, ^expected_payload}, 500

    assert_receive {^reply_ref,
                    {:ok,
                     %{
                       agent_id: "agent-router-sync",
                       scan_id: "scan-router-sync",
                       directives: %{"endpoint_inventory" => %{"reconcile_floor" => true}}
                     }}},
                   500

    assert_receive {:DOWN, ^task_monitor, :process, ^task_pid, :normal}, 500
  end

  describe "async batching" do
    setup do
      Application.put_env(:serviceradar_core, :results_router_batching, true)
      :ok
    end

    test "cast buffers statuses and flush routes them per item" do
      Application.put_env(:serviceradar_core, :results_router_max_buffer, 200)

      status = fn ip ->
        %{
          source: "results",
          service_type: "sync",
          message: Jason.encode!([%{"device_id" => "dev-#{ip}", "ip" => ip}])
        }
      end

      init_state = %{buffer: [], buffer_size: 0, timer: nil}

      assert {:noreply, state1} =
               ResultsRouter.handle_cast({:results_update, status.("10.0.0.1")}, init_state)

      assert state1.buffer_size == 1

      assert {:noreply, state2} =
               ResultsRouter.handle_cast({:results_update, status.("10.0.0.2")}, state1)

      assert state2.buffer_size == 2

      # Buffered, not yet flushed: the routed ingestor has not fired.
      refute_receive {:ingest, _updates, _opts}, 50

      # Timer-driven flush routes every buffered status individually.
      assert {:noreply, flushed} = ResultsRouter.handle_info(:flush_results, state2)
      assert flushed.buffer_size == 0
      assert flushed.buffer == []

      assert_receive {:ingest, [%{"ip" => "10.0.0.1"}], _opts1}
      assert_receive {:ingest, [%{"ip" => "10.0.0.2"}], _opts2}
    end

    test "buffer flushes immediately when max buffer is reached" do
      Application.put_env(:serviceradar_core, :results_router_max_buffer, 2)

      status = fn ip ->
        %{
          source: "results",
          service_type: "sync",
          message: Jason.encode!([%{"device_id" => "dev-#{ip}", "ip" => ip}])
        }
      end

      init_state = %{buffer: [], buffer_size: 0, timer: nil}

      assert {:noreply, state1} =
               ResultsRouter.handle_cast({:results_update, status.("10.0.0.1")}, init_state)

      refute_receive {:ingest, _updates, _opts}, 50

      # Second cast hits max_buffer (2) and flushes inline.
      assert {:noreply, state2} =
               ResultsRouter.handle_cast({:results_update, status.("10.0.0.2")}, state1)

      assert state2.buffer_size == 0
      assert_receive {:ingest, [%{"ip" => "10.0.0.1"}], _opts1}
      assert_receive {:ingest, [%{"ip" => "10.0.0.2"}], _opts2}
    end
  end

  defp metric_batch_fixture, do: <<10, 22, "serviceradar.metric.v1">>

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
