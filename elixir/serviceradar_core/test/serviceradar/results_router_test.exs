defmodule ServiceRadar.ResultsRouterTest do
  @moduledoc """
  Tests for sweep result ingestion and runtime metric persistence.

  DB connection's search_path determines the schema.
  """

  use ServiceRadar.DataCase, async: false

  alias ServiceRadar.Analytics.StarRocks.LoadSupervisor
  alias ServiceRadar.EventWriter.Processors.Metrics
  alias ServiceRadar.Ingestion.ResultIngestor
  alias ServiceRadar.Ingestion.RuntimeMetrics

  defmodule TestSweepIngestor do
    @moduledoc false
    def ingest_results(results, execution_id, opts) do
      send(self(), {:sweep_ingest, results, execution_id, opts})
      {:ok, %{hosts_total: length(results)}}
    end
  end

  setup do
    previous_sweep = Application.get_env(:serviceradar_core, :sweep_ingestor)
    Application.put_env(:serviceradar_core, :sweep_ingestor, TestSweepIngestor)

    on_exit(fn ->
      if is_nil(previous_sweep) do
        Application.delete_env(:serviceradar_core, :sweep_ingestor)
      else
        Application.put_env(:serviceradar_core, :sweep_ingestor, previous_sweep)
      end
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
    RuntimeMetrics.record(:other_results, :state, %{pending_count: 3})
    RuntimeMetrics.record(:other_results, :admitted, %{count: 4})
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
end
