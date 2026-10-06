defmodule ServiceRadar.ResultsRouterTest do
  @moduledoc """
  Tests for results ingestion routing in ResultsRouter.

  DB connection's search_path determines the schema.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Analytics.StarRocks.LoadSupervisor
  alias ServiceRadar.EventWriter.Processors.Metrics
  alias ServiceRadar.Ingestion.Admission
  alias ServiceRadar.Ingestion.ResultIngestor
  alias ServiceRadar.Ingestion.RuntimeMetrics
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

  defmodule LoadSweepIngestor do
    @moduledoc false
    def ingest_results(results, execution_id, opts) do
      if Application.get_env(:serviceradar_core, :ingestion_load_barrier, false) do
        parent = Application.fetch_env!(:serviceradar_core, :ingestion_load_test_pid)
        send(parent, {:load_sweep_held, self()})

        receive do
          :release_load_sweep -> :ok
        end
      end

      ServiceRadar.ResultsRouterTest.TestSweepIngestor.ingest_results(results, execution_id, opts)
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

    # Type routing and persistence are owned by the worker. Queue lifecycle and
    # ordering are exercised separately through the actual supervised dispatcher.
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

  test "ingestion metric envelopes persist through exactly the configured EventWriter backend" do
    parent = self()

    request = fn _subject, body, _opts ->
      send(parent, {:ingestion_metric_wire, body})
      {:ok, %{body: Jason.encode!(%{stream: "METRICS", seq: 1})}}
    end

    start_supervised!({RuntimeMetrics, interval_ms: 20, publish_opts: [request: request]})
    RuntimeMetrics.record(:mapper, :state, %{pending_count: 3})
    RuntimeMetrics.record(:mapper, :admitted, %{count: 4})
    assert_receive {:ingestion_metric_wire, body}, 1_000
    stop_supervised!(RuntimeMetrics)
    message = %{data: body, metadata: %{subject: "metrics.ingestion_lanes"}}
    key = ServiceRadar.Analytics.StarRocks
    previous = Application.get_env(:serviceradar_core, key, [])
    on_exit(fn -> Application.put_env(:serviceradar_core, key, previous) end)
    Application.put_env(:serviceradar_core, key, enabled: false)
    assert {:ok, count} = Metrics.process_batch([message])
    assert count > 0

    assert %{rows: [[3.0, false]]} =
             ServiceRadar.Repo.query!(
               "SELECT value, is_delta FROM platform.timeseries_metrics WHERE metric_type = $1 AND metric_name = $2",
               ["core.result_ingestion", "result_ingestion_pending_count"]
             )

    assert %{rows: [[4.0, true]]} =
             ServiceRadar.Repo.query!(
               "SELECT value, is_delta FROM platform.timeseries_metrics WHERE metric_type = $1 AND metric_name = $2",
               ["core.result_ingestion", "result_ingestion_events_admitted"]
             )

    # Remove this test's points before the warehouse pass. A duplicate CNPG
    # insert must not hide dual writes behind the conflict policy.
    ServiceRadar.Repo.query!(
      "DELETE FROM platform.timeseries_metrics WHERE metric_type = $1",
      ["core.result_ingestion"]
    )

    {:ok, listener} =
      :gen_tcp.listen(
        0,
        [:binary, packet: :line, active: false, ip: {127, 0, 0, 1}]
      )

    {:ok, {_ip, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    start_supervised!(
      {Task,
       fn ->
         {:ok, socket} = :gen_tcp.accept(listener, 5_000)
         {:ok, first_line} = :gen_tcp.recv(socket, 0, 5_000)
         headers = read_load_headers(socket, [])

         if Enum.any?(headers, &String.starts_with?(&1, "expect: 100-continue")),
           do: :gen_tcp.send(socket, "HTTP/1.1 100 Continue\r\n\r\n")

         content_length =
           headers
           |> Enum.find(&String.starts_with?(&1, "content-length:"))
           |> String.split(":", parts: 2)
           |> List.last()
           |> String.trim()
           |> String.to_integer()

         :ok = :inet.setopts(socket, packet: :raw)
         {:ok, payload} = :gen_tcp.recv(socket, content_length, 5_000)
         rows = Jason.decode!(payload)
         send(parent, {:warehouse_ingestion_metrics, first_line, rows})

         response =
           Jason.encode!(%{
             "Status" => "Success",
             "NumberLoadedRows" => length(rows),
             "NumberFilteredRows" => 0
           })

         :ok =
           :gen_tcp.send(socket, [
             "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ",
             Integer.to_string(byte_size(response)),
             "\r\nConnection: close\r\n\r\n",
             response
           ])

         :gen_tcp.close(socket)
       end},
      id: :metric_warehouse
    )

    if !Process.whereis(LoadSupervisor),
      do: start_supervised!(LoadSupervisor)

    Application.put_env(:serviceradar_core, key,
      enabled: true,
      fe_http: "http://127.0.0.1:#{port}",
      database: "fixture",
      user: "fixture",
      password: ""
    )

    assert {:ok, ^count} = Metrics.process_batch([message])
    assert_receive {:warehouse_ingestion_metrics, request_line, rows}, 1_000
    assert String.contains?(request_line, "/timeseries_metrics/_stream_load")
    assert Enum.all?(rows, &(&1["metric_type"] == "core.result_ingestion"))

    admitted_row =
      Enum.find(rows, &(&1["metric_name"] == "result_ingestion_events_admitted"))

    assert admitted_row["value"] == 4.0
    assert admitted_row["is_delta"] == true

    gauge_row =
      Enum.find(rows, &(&1["metric_name"] == "result_ingestion_pending_count"))

    assert gauge_row["value"] == 3.0
    assert gauge_row["is_delta"] == false

    assert %{rows: [[0]]} =
             ServiceRadar.Repo.query!(
               "SELECT count(*) FROM platform.timeseries_metrics WHERE metric_type = $1",
               ["core.result_ingestion"]
             )
  end

  defp read_load_headers(socket, headers) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, "\r\n"} -> headers
      {:ok, line} -> read_load_headers(socket, [String.downcase(line) | headers])
      {:error, reason} -> flunk("warehouse HTTP headers failed: #{inspect(reason)}")
    end
  end

  @tag timeout: 30_000
  test "synthetic burst isolates held sweeps and reconciles bounded terminal replies" do
    parent = self()
    prefix = "load-#{System.unique_integer([:positive])}"
    previous_barrier = Application.fetch_env(:serviceradar_core, :ingestion_load_barrier)
    previous_pid = Application.fetch_env(:serviceradar_core, :ingestion_load_test_pid)
    Application.put_env(:serviceradar_core, :sweep_ingestor, LoadSweepIngestor)
    Application.put_env(:serviceradar_core, :ingestion_load_barrier, true)
    Application.put_env(:serviceradar_core, :ingestion_load_test_pid, parent)

    on_exit(fn ->
      for {key, previous} <- [
            {:ingestion_load_barrier, previous_barrier},
            {:ingestion_load_test_pid, previous_pid}
          ] do
        case previous do
          {:ok, value} -> Application.put_env(:serviceradar_core, key, value)
          :error -> Application.delete_env(:serviceradar_core, key)
        end
      end
    end)

    ServiceRadar.TestSupport.start_ingestion_topology!()
    telemetry_id = "result-ingestion-load-#{Ecto.UUID.generate()}"
    repo_query_event = Keyword.fetch!(ServiceRadar.Repo.config(), :telemetry_prefix) ++ [:query]

    :ok =
      :telemetry.attach_many(
        telemetry_id,
        [
          [:serviceradar, :admission_lane, :state],
          [:serviceradar, :admission_lane, :admitted],
          [:serviceradar, :admission_lane, :completion],
          [:serviceradar, :admission_lane, :rejected],
          repo_query_event
        ],
        fn event, measurements, metadata, pid ->
          send(pid, {:load_telemetry, event, measurements, metadata, self()})
        end,
        parent
      )

    on_exit(fn -> :telemetry.detach(telemetry_id) end)

    tasks = start_supervised!(Supervisor.child_spec({Task.Supervisor, []}, id: :load_clients))
    offered = for type <- [:sweep, :endpoint, :plugin], index <- 1..64, do: {type, index}

    for {type, index} <- offered do
      {:ok, _pid} =
        Task.Supervisor.start_child(tasks, fn ->
          status = load_status(type, index, prefix)
          started = System.monotonic_time(:millisecond)

          result =
            with {:ok, {lane, token}} <-
                   GenServer.call(
                     ServiceRadar.StatusHandler,
                     {:reserve_status, ServiceRadar.Admission.Lane.descriptor(status, 15_000)},
                     1_000
                   ) do
              GenServer.call(lane, {:submit, token, status, :wait}, 15_000)
            end

          send(parent, {:load_reply, type, result, System.monotonic_time(:millisecond) - started})
        end)
    end

    # Both fast classes must reach terminal replies while the slow class still
    # owns its workers and general Repo permits. No sleep guesses completion.
    {fast, held} = collect_load_fast([], MapSet.new(), 128)
    assert map_size(:sys.get_state(Admission.server(:sweep)).jobs) > 0

    assert Enum.any?(fast, fn {type, result, _} ->
             type == :endpoint and match?({:ok, _}, result)
           end)

    assert Enum.any?(fast, fn {type, result, _} -> type == :plugin and result == :ok end)
    Application.put_env(:serviceradar_core, :ingestion_load_barrier, false)
    Enum.each(held, &send(&1, :release_load_sweep))
    replies = collect_load_remaining(fast, length(offered))

    for type <- [:sweep, :endpoint] do
      assert_eventually(fn -> :sys.get_state(Admission.server(type)).jobs == %{} end)
    end

    assert_eventually(fn ->
      :sys.get_state(ServiceRadar.Admission.RetainedPluginLane).jobs == %{}
    end)

    :telemetry.detach(telemetry_id)
    evidence = collect_load_telemetry([])

    completed =
      Enum.filter(replies, fn {_, result, _} -> result == :ok or match?({:ok, _}, result) end)

    rejected = Enum.filter(replies, fn {_, result, _} -> match?({:error, _}, result) end)
    assert length(completed) + length(rejected) == length(offered)
    assert rejected != []
    depths = for {[:serviceradar, :admission_lane, :state], m, _, _} <- evidence, do: m
    assert Enum.all?(depths, &(&1.pending_count + &1.in_flight_count <= 32))
    assert Enum.all?(depths, &(&1.pending_bytes + &1.in_flight_bytes <= 64 * 1_024 * 1_024))
    owners = for {event, _, _, pid} <- evidence, event == repo_query_event, do: pid
    assert owners != []
    refute Process.whereis(ServiceRadar.StatusHandler) in owners
    refute Process.whereis(ResultsRouter) in owners

    persisted = Enum.count(completed, fn {type, _, _} -> type != :plugin end)

    assert %{rows: [[^persisted]]} =
             ServiceRadar.Repo.query!(
               "SELECT count(*) FROM platform.service_state WHERE service_name LIKE $1",
               [prefix <> "-%"]
             )

    latencies = replies |> Enum.map(&elem(&1, 2)) |> Enum.sort()
    p99 = Enum.at(latencies, ceil(length(latencies) * 0.99) - 1)
    assert p99 < 15_000
    assert List.last(latencies) < 20_000

    IO.puts(
      "RESULT_INGESTION_SYNTHETIC_LOAD " <>
        Jason.encode!(%{
          offered: length(offered),
          completed: length(completed),
          rejected: length(rejected),
          persisted_service_states: persisted,
          slow_class: "sweep",
          live: false,
          max_retained_bytes:
            Enum.max(Enum.map(depths, &(&1.pending_bytes + &1.in_flight_bytes))),
          ack_p50_ms: Enum.at(latencies, ceil(length(latencies) * 0.50) - 1),
          ack_p95_ms: Enum.at(latencies, ceil(length(latencies) * 0.95) - 1),
          ack_p99_ms: p99,
          ack_max_ms: List.last(latencies)
        })
    )
  end

  defp load_status(type, index, prefix) do
    base = %{
      agent_id: "agent#{index}.example.com",
      gateway_id: "gateway01.example.com",
      partition: "default",
      service_name: "#{prefix}-#{type}-#{index}",
      available: true
    }

    case type do
      :sweep ->
        Map.merge(base, %{
          source: "results",
          service_type: "sweep",
          message: Jason.encode!(%{"hosts" => [%{"host" => "192.0.2.61", "available" => true}]})
        })

      :endpoint ->
        Map.merge(base, %{
          source: "results",
          service_type: "endpoint_inventory",
          message: Jason.encode!(%{"agent_id" => base.agent_id, "scan_id" => "scan-#{index}"})
        })

      :plugin ->
        Map.merge(base, %{
          source: "plugin-result",
          service_type: "plugin",
          delivery_capabilities: ["plugin-result-retained:v1"],
          message: Jason.encode!(%{"result" => index})
        })
    end
  end

  defp collect_load_fast(replies, held, 0), do: {replies, held}

  defp collect_load_fast(replies, held, remaining) do
    receive do
      {:load_reply, type, result, latency} when type in [:endpoint, :plugin] ->
        collect_load_fast([{type, result, latency} | replies], held, remaining - 1)

      {:load_reply, :sweep, result, latency} ->
        collect_load_fast([{:sweep, result, latency} | replies], held, remaining)

      {:load_sweep_held, pid} ->
        collect_load_fast(replies, MapSet.put(held, pid), remaining)
    after
      12_000 -> flunk("fast result classes did not reply while sweep was held")
    end
  end

  defp collect_load_remaining(replies, total) when length(replies) == total, do: replies

  defp collect_load_remaining(replies, total) do
    receive do
      {:load_reply, type, result, latency} ->
        collect_load_remaining([{type, result, latency} | replies], total)

      {:load_sweep_held, pid} ->
        send(pid, :release_load_sweep)
        collect_load_remaining(replies, total)
    after
      12_000 -> flunk("admitted load did not drain")
    end
  end

  defp collect_load_telemetry(events) do
    receive do
      {:load_telemetry, event, measurements, metadata, pid} ->
        collect_load_telemetry([{event, measurements, metadata, pid} | events])
    after
      0 -> events
    end
  end

  test "ingests sync updates" do
    status = %{
      source: "results",
      service_type: "sync",
      message: Jason.encode!([%{"device_id" => "dev-1", "ip" => "10.0.0.1"}])
    }

    assert :ok = ResultIngestor.process_and_publish(status)

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

    assert :ok = ResultIngestor.process_and_publish(status)

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

    assert :ok = ResultIngestor.process_and_publish(status)

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

    assert :ok = ResultIngestor.process_and_publish(first_status)
    assert :ok = ResultIngestor.process_and_publish(second_status)

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

    assert {:error, {:invalid_sync_results, :unexpected_payload}} =
             ResultIngestor.process_and_publish(status)

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

    assert :ok = ResultIngestor.process_and_publish(status)

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

    assert :ok = ResultIngestor.process_and_publish(status)

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

    assert :ok = ResultIngestor.process_and_publish(status)

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

    assert :ok = ResultIngestor.process_and_publish(status)

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

    assert {:error, :unsupported_payload} = ResultIngestor.process_and_publish(status)
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

    assert {:error, {:gateway_metric_status_not_core_routable, "sysmon-metrics"}} =
             ResultIngestor.process_and_publish(status)

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

    assert {:error, {:gateway_metric_status_not_core_routable, "snmp-metrics"}} =
             ResultIngestor.process_and_publish(status)
  end

  test "rejects direct core routing for ICMP metric statuses" do
    status = %{
      source: "icmp-metrics",
      service_type: "icmp",
      message: metric_batch_fixture(),
      agent_id: "agent-1",
      gateway_id: "gateway-1"
    }

    assert {:error, {:gateway_metric_status_not_core_routable, "icmp-metrics"}} =
             ResultIngestor.process_and_publish(status)
  end

  test "rejects direct core routing for rperf metric statuses" do
    status = %{
      source: "rperf-metrics",
      service_type: "rperf",
      message: metric_batch_fixture(),
      agent_id: "agent-1",
      gateway_id: "gateway-1"
    }

    assert {:error, {:gateway_metric_status_not_core_routable, "rperf-metrics"}} =
             ResultIngestor.process_and_publish(status)
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

    assert :ok = ResultIngestor.process_and_publish(status)

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

    assert {:error, :plugin_result_metrics_unsupported} =
             ResultIngestor.process_and_publish(status)

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

    assert ^error = ResultIngestor.process_and_publish(status)

    assert_receive {:plugin_ingest, ^payload, ^status}
  end

  test "routes asynchronous endpoint inventory payloads through bounded queue" do
    ServiceRadar.TestSupport.start_ingestion_topology!()
    Application.put_env(:serviceradar_core, :endpoint_inventory_ingestor_async, true)

    payload = %{"scan_id" => "scan-router-async"}

    status = %{
      source: "results",
      service_type: "endpoint_inventory",
      message: Jason.encode!(payload),
      agent_id: "agent-router-async"
    }

    GenServer.cast(ResultsRouter, {:results_update, status})

    expected_payload = Map.put(payload, "agent_id", "agent-router-async")
    assert_receive {:endpoint_inventory_ingest, ^expected_payload, opts}, 500
    assert Keyword.keyword?(opts)
  end

  test "endpoint inventory bypasses a busy router and replies only on ingest completion" do
    ServiceRadar.TestSupport.start_ingestion_topology!()
    :ok = :sys.suspend(ResultsRouter)

    on_exit(fn ->
      if Process.whereis(ResultsRouter), do: :sys.resume(ResultsRouter)
    end)

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

    caller =
      start_supervised!(
        {Task,
         fn ->
           result = GenServer.call(ServiceRadar.StatusHandler, {:status_update, status}, 5_000)
           send(elem(reply_to, 0), {elem(reply_to, 1), result})
         end}
      )

    assert is_pid(caller)

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

  describe "completed service-state batching" do
    setup do
      ServiceRadar.TestSupport.start_ingestion_topology!()
      previous = Application.get_env(:serviceradar_core, :results_router_flush_interval_ms)
      Application.put_env(:serviceradar_core, :results_router_flush_interval_ms, 60_000)
      on_exit(fn -> restore_env(:results_router_flush_interval_ms, previous) end)
      :ok = ServiceRadar.Observability.ServiceStatusPubSub.subscribe()
      :ok
    end

    test "a stale flush cannot consume a newer batch" do
      first = completed_status("first")
      second = completed_status("second")
      assert :ok = ResultsRouter.publish_completed(first)
      {_timer, first_token} = :sys.get_state(ResultsRouter).timer
      send(ResultsRouter, {:flush_results, first_token})
      assert_receive {:service_statuses_updated, [^first]}, 1_000
      assert_state_persisted("first")

      assert :ok = ResultsRouter.publish_completed(second)
      {_timer, second_token} = :sys.get_state(ResultsRouter).timer
      send(ResultsRouter, {:flush_results, first_token})
      send(ResultsRouter, :flush_results)
      refute_receive {:service_statuses_updated, _}, 100
      send(ResultsRouter, {:flush_results, second_token})
      assert_receive {:service_statuses_updated, [^second]}, 1_000
      assert_state_persisted("second")
    end

    test "a late older observation cannot replace the pending current-state winner" do
      latest_at = ~U[2026-01-01 00:01:00.000000Z]
      older_at = ~U[2026-01-01 00:00:00.000000Z]

      latest =
        Map.merge(completed_status("ordered"), %{agent_timestamp: latest_at, available: false})

      older =
        Map.merge(completed_status("ordered"), %{agent_timestamp: older_at, available: true})

      assert :ok = ResultsRouter.publish_completed(latest)
      assert :ok = ResultsRouter.publish_completed(older)
      {_timer, token} = :sys.get_state(ResultsRouter).timer
      send(ResultsRouter, {:flush_results, token})
      assert_receive {:service_statuses_updated, [^latest]}, 1_000

      assert %{rows: [[false, persisted_at]]} =
               ServiceRadar.Repo.query!(
                 "SELECT available, last_observed_at FROM platform.service_state WHERE agent_id = $1 AND service_name = $2",
                 ["fixture-agent", "ordered"]
               )

      persisted_at =
        case persisted_at do
          %NaiveDateTime{} -> DateTime.from_naive!(persisted_at, "Etc/UTC")
          %DateTime{} -> persisted_at
        end

      assert persisted_at == latest_at
    end

    test "a full completed-state batch flushes and releases admission capacity" do
      Application.put_env(:serviceradar_core, :results_router_max_buffer, 2)
      first = completed_status("first")
      second = completed_status("second")
      assert :ok = ResultsRouter.publish_completed(first)
      refute_receive {:service_statuses_updated, _}, 50
      assert :ok = ResultsRouter.publish_completed(second)
      assert_receive {:service_statuses_updated, [^first, ^second]}, 1_000
      assert_state_persisted("first")
      assert_state_persisted("second")
      # Completion releases credits only once the writer has exited.
      assert_eventually(fn ->
        ResultsRouter.publish_completed(completed_status("third")) == :ok
      end)
    end
  end

  defp assert_state_persisted(name) do
    assert %{rows: [[true]]} =
             ServiceRadar.Repo.query!(
               "SELECT available FROM platform.service_state WHERE agent_id = $1 AND service_name = $2",
               ["fixture-agent", name]
             )
  end

  defp completed_status(name) do
    %{
      source: "results",
      service_type: "sync",
      service_name: name,
      agent_id: "fixture-agent",
      gateway_id: "fixture-gateway",
      partition: "default",
      available: true,
      message: "completed",
      timestamp: DateTime.utc_now()
    }
  end

  defp assert_eventually(predicate, attempts \\ 40)

  defp assert_eventually(predicate, attempts) when attempts > 0 do
    if predicate.(),
      do: :ok,
      else:
        (
          Process.sleep(25)
          assert_eventually(predicate, attempts - 1)
        )
  end

  defp assert_eventually(_predicate, 0), do: flunk("admission capacity was not released")

  defp metric_batch_fixture, do: <<10, 22, "serviceradar.metric.v1">>

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_core, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_core, key, value)
end
