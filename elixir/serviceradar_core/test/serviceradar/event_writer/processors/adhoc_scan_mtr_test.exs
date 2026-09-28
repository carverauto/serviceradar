defmodule ServiceRadar.EventWriter.Processors.AdhocScanMtrTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.EventWriter.Processors.AdhocScan

  @moduletag :db_free

  @scan_run_id "6d5c4b3a-2918-4706-a5b4-c3d2e1f0a9b8"

  defp msg(map), do: %{data: Jason.encode!(map), metadata: %{}}

  defp mtr_message(target_ip) do
    msg(%{
      "scan_run_id" => @scan_run_id,
      "agent_id" => "agent-01",
      "gateway_id" => "gateway-01",
      "target_ip" => target_ip,
      "mode" => "mtr",
      "available" => true,
      "timestamp_ms" => 1_780_000_000_000,
      "trace" => %{
        "target_ip" => target_ip,
        "hops" => [%{"hop_number" => 1, "addr" => target_ip, "asn" => %{"asn" => 64_500}}]
      }
    })
  end

  defp icmp_message(target_ip) do
    msg(%{
      "scan_run_id" => @scan_run_id,
      "agent_id" => "agent-01",
      "target_ip" => target_ip,
      "mode" => "icmp",
      "available" => true,
      "timestamp_ms" => 1_780_000_000_000
    })
  end

  # The adhoc_scan_results insert, recorded instead of written.
  defp opts(extra) do
    test_pid = self()

    Keyword.merge(
      [
        insert: fn table, rows, _opts ->
          send(test_pid, {:insert, table, rows})
          {length(rows), nil}
        end
      ],
      extra
    )
  end

  defp warehouse(extra \\ []) do
    test_pid = self()

    [
      starrocks_enabled: true,
      ingest: fn _payload, _status, _opts -> flunk("CNPG must not be written") end,
      load: fn dataset, rows ->
        send(test_pid, {:load, dataset, rows})
        {:ok, %{loaded: length(rows)}}
      end,
      project: fn _results, _status -> :ok end
    ]
    |> Keyword.merge(extra)
    |> opts()
  end

  test "MTR traces go to the warehouse through the shared MTR persistence" do
    messages = [mtr_message("192.0.2.30"), icmp_message("192.0.2.31")]

    assert {:ok, 2} = AdhocScan.process_batch(messages, warehouse())

    assert_received {:insert, "adhoc_scan_results", [_, _]}
    assert_received {:load, :mtr_traces, [trace]}
    assert_received {:load, :mtr_hops, [%{trace_id: trace_id}]}
    assert trace.target_ip == "192.0.2.30"
    assert trace.agent_id == "agent-01"
    assert trace.gateway_id == "gateway-01"
    assert trace_id == trace.id
    # The scan row's time stands in for a trace without a timestamp.
    assert trace.time == ~U[2026-05-28 20:26:40.000000Z]
    refute_received {:load, :mtr_traces, _}
  end

  test "MTR traces go to CNPG, skipping stored traces, when StarRocks is disabled" do
    test_pid = self()

    ingest = fn payload, status, opts ->
      send(test_pid, {:ingest, payload, status, opts})
      :ok
    end

    load = fn _dataset, _rows -> flunk("the warehouse must not be written") end

    assert {:ok, 1} =
             AdhocScan.process_batch(
               [mtr_message("192.0.2.40")],
               opts(starrocks_enabled: false, ingest: ingest, load: load)
             )

    assert_received {:ingest, %{"trace_uuid" => trace_uuid, "target" => "192.0.2.40"},
                     %{agent_id: "agent-01"}, [skip_existing: true]}

    assert {:ok, _} = Ecto.UUID.cast(trace_uuid)
  end

  test "a redelivered message stores the same ids" do
    ids = fn ->
      assert {:ok, 1} = AdhocScan.process_batch([mtr_message("192.0.2.50")], warehouse())
      assert_received {:insert, _table, [%{id: row_id}]}
      assert_received {:load, :mtr_traces, [%{id: trace_id}]}
      assert_received {:load, :mtr_hops, [%{id: hop_id}]}
      {row_id, trace_id, hop_id}
    end

    assert ids.() == ids.()
  end

  test "a warehouse failure fails the batch so JetStream redelivers it" do
    load = fn _dataset, _rows -> {:error, {:warehouse_load, :mtr_traces, :connect_failed}} end

    assert {:error, {:warehouse_load, :mtr_traces, :connect_failed}} =
             AdhocScan.process_batch([mtr_message("192.0.2.60")], warehouse(load: load))
  end

  test "a batch without MTR rows loads nothing" do
    load = fn _dataset, _rows -> flunk("no MTR rows") end

    assert {:ok, 1} =
             AdhocScan.process_batch([icmp_message("192.0.2.70")], warehouse(load: load))
  end
end
