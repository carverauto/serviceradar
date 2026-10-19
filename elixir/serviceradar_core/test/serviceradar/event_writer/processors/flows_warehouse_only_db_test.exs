defmodule ServiceRadar.EventWriter.Processors.FlowsWarehouseOnlyDBTest do
  @moduledoc """
  NetFlow, sFlow and IPFIX flows are stored in StarRocks or not at all.

  With the warehouse enabled a flow batch is Stream Loaded to it and the legacy
  CNPG `ocsf_network_activity` hypertable does not exist. Without the warehouse
  the batch is acknowledged, stored nowhere, and the refusal is logged once
  rather than per batch.
  """
  use ServiceRadar.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL
  alias Flowpb.FlowMessage
  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadar.EventWriter.Processors.Flows
  alias ServiceRadar.Repo

  @moduletag :integration

  @src_ip "192.0.2.10"
  @dst_ip "198.51.100.20"
  @refusal "NetFlow ingestion requires StarRocks"

  setup do
    previous = Application.get_env(:serviceradar_core, StarRocks)
    on_exit(fn -> Application.put_env(:serviceradar_core, StarRocks, previous || []) end)
    :ok
  end

  test "with StarRocks enabled a flow batch is loaded into the warehouse and not written to CNPG" do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, reuseaddr: true])

    {:ok, {_ip, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)
    parent = self()
    start_supervised!({Task, fn -> serve_stream_loads(listener, parent) end})

    put_starrocks(enabled: true, fe_http: "http://127.0.0.1:#{port}")

    assert {:ok, 1} = Flows.process_batch([flow_message()])

    assert_receive {:wire_request, [row]}, 5_000
    assert row["src_endpoint_ip"] == @src_ip
    assert row["dst_endpoint_ip"] == @dst_ip
    refute cnpg_flow_table_present?()
  end

  test "without StarRocks a flow batch is acknowledged, stored nowhere, and refused once" do
    put_starrocks(enabled: false)
    :persistent_term.erase({Flows, :starrocks_required_logged})

    log =
      capture_log(fn ->
        assert {:ok, 0} = Flows.process_batch([flow_message()])
        assert {:ok, 0} = Flows.process_batch([flow_message()])
      end)

    assert log |> String.split(@refusal) |> length() == 2
    refute cnpg_flow_table_present?()
  end

  defp put_starrocks(overrides) do
    previous = Application.get_env(:serviceradar_core, StarRocks) || []
    Application.put_env(:serviceradar_core, StarRocks, Keyword.merge(previous, overrides))
  end

  defp flow_message do
    now = System.system_time(:nanosecond)

    flow = %FlowMessage{
      type: :NETFLOW_V5,
      time_received_ns: now,
      time_flow_start_ns: now - 10_000_000_000,
      time_flow_end_ns: now - 5_000_000_000,
      sampler_address: <<192, 0, 2, 1>>,
      src_addr: <<192, 0, 2, 10>>,
      dst_addr: <<198, 51, 100, 20>>,
      src_port: 49_152,
      dst_port: 443,
      proto: 6,
      bytes: 1_500,
      packets: 3
    }

    %{data: FlowMessage.encode(flow), metadata: %{subject: "flows.raw.netflow"}}
  end

  defp cnpg_flow_table_present? do
    %{rows: [[present?]]} =
      SQL.query!(Repo, "SELECT to_regclass('platform.ocsf_network_activity') IS NOT NULL", [])

    present?
  end

  # A StarRocks FE that accepts every Stream Load and reports each row loaded.
  defp serve_stream_loads(listener, parent) do
    case :gen_tcp.accept(listener, 5_000) do
      {:ok, socket} ->
        {:ok, {:http_request, :PUT, _, _}} = :gen_tcp.recv(socket, 0, 5_000)
        headers = receive_headers(socket, %{})
        :ok = :gen_tcp.send(socket, "HTTP/1.1 100 Continue\r\n\r\n")
        :ok = :inet.setopts(socket, packet: :raw)
        {:ok, body} = :gen_tcp.recv(socket, String.to_integer(headers["content-length"]), 5_000)
        rows = Jason.decode!(body)
        send(parent, {:wire_request, rows})

        response =
          Jason.encode!(%{
            "Status" => "Success",
            "NumberLoadedRows" => length(rows),
            "NumberFilteredRows" => 0
          })

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ",
            Integer.to_string(byte_size(response)),
            "\r\n\r\n",
            response
          ])

        :gen_tcp.close(socket)
        serve_stream_loads(listener, parent)

      {:error, :closed} ->
        :ok

      {:error, :timeout} ->
        serve_stream_loads(listener, parent)
    end
  end

  defp receive_headers(socket, headers) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, :http_eoh} ->
        headers

      {:ok, {:http_header, _, key, _, value}} ->
        receive_headers(socket, Map.put(headers, key |> to_string() |> String.downcase(), value))
    end
  end
end
