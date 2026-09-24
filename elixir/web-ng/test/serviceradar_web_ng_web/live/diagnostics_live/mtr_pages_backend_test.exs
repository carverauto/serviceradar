defmodule ServiceRadarWebNGWeb.DiagnosticsLive.MtrPagesBackendTest do
  # Not async: the StarRocks switch is global application env.
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrCompare
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrTrace

  @moduletag :db_free

  # Every value below is synthetic: documentation address ranges, invented ids.
  @trace_id "5d2f8a1e-7b3c-4e9a-8f60-1a2b3c4d5e6f"

  @trace_row %{
    "id" => @trace_id,
    "time" => ~N[2026-01-01 12:00:00],
    "agent_id" => "agent-01",
    "gateway_id" => "gateway-01",
    "check_id" => "check-01",
    "check_name" => "ping",
    "device_id" => "sr:device-01",
    "target" => "host01.example.com",
    "target_ip" => "198.51.100.20",
    "target_reached" => 1,
    "total_hops" => 2,
    "probed_hops" => 2,
    "last_responding_hop" => 2,
    "protocol" => "tcp",
    "tcp_port" => 443,
    "ip_version" => 4,
    "packet_size" => 64,
    "partition" => "default",
    "error" => nil,
    "tcp_handshake_ttl" => 60,
    "tcp_handshake_attempts" => 1,
    "tcp_syn_sent" => 3,
    "tcp_synack_received" => 3,
    "tcp_rst_received" => 0,
    "tcp_syn_unanswered" => 0,
    "tcp_syn_drop_pct" => 0.0,
    "tcp_syn_retransmits" => 0,
    "tcp_answered_after_retx" => 0,
    "tcp_ack_mismatch" => 0,
    "tcp_synack_duplicates" => 0,
    "tcp_handshake_rtt_min_us" => 900,
    "tcp_handshake_rtt_avg_us" => 1_000,
    "tcp_handshake_rtt_max_us" => 1_100,
    "tcp_server_response_us" => 1_200
  }

  @hop_row %{
    "id" => "hop-01",
    "time" => ~N[2026-01-01 12:00:01],
    "hop_number" => 1,
    "addr" => "198.51.100.1",
    "hostname" => "host02.example.com",
    "ecmp_addrs" => "[]",
    "asn" => nil,
    "asn_org" => nil,
    "mpls_labels" => nil,
    "sent" => 10,
    "received" => 10,
    "loss_pct" => 0.0,
    "last_us" => 800,
    "avg_us" => 850,
    "min_us" => 700,
    "max_us" => 900,
    "stddev_us" => 40,
    "jitter_us" => 20,
    "jitter_worst_us" => 60,
    "jitter_interarrival_us" => 15,
    "unreachable_code" => nil,
    "reply_time_exceeded" => 10,
    "reply_unreachable" => 0,
    "reply_synack" => 0,
    "reply_rst" => 0
  }

  setup do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])
    on_exit(fn -> Application.put_env(:serviceradar_core, StarRocks, prev) end)
    %{prev: prev}
  end

  defp enable_warehouse(prev, enabled?) do
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev |> Keyword.put(:enabled, enabled?) |> Keyword.put(:cutover_datasets, [])
    )
  end

  # Answers the trace lookup with @trace_row and the hop lookup with @hop_row,
  # the way the warehouse returns them: columns plus positional rows.
  defp detail_warehouse do
    test = self()

    fn sql ->
      send(test, {:warehouse, sql})

      row =
        cond do
          sql =~ "FROM serviceradar.mtr_hops" -> @hop_row
          sql =~ "FROM serviceradar.mtr_traces" -> @trace_row
        end

      {:ok, %{columns: Map.keys(row), rows: [Map.values(row)]}}
    end
  end

  test "with StarRocks disabled the pages keep their Ash reads and never ask the warehouse", %{prev: prev} do
    enable_warehouse(prev, false)
    test = self()

    warehouse = fn sql ->
      send(test, {:warehouse, sql})
      {:error, :warehouse_must_not_be_queried}
    end

    # No database runs under this test, so the Ash reads fail however they fail;
    # what matters is that none of them is answered by the warehouse.
    for read <- [
          fn -> MtrTrace.fetch_trace(@trace_id, nil, starrocks_query: warehouse) end,
          fn -> MtrTrace.hop_sparklines([%{"addr" => "198.51.100.1"}], nil, starrocks_query: warehouse) end,
          fn -> MtrCompare.recent_traces(nil, starrocks_query: warehouse) end,
          fn -> MtrCompare.load_trace_with_hops(@trace_id, nil, starrocks_query: warehouse) end
        ] do
      try do
        read.()
      rescue
        _error -> :ash_read_failed
      catch
        :exit, _reason -> :ash_read_failed
      end
    end

    refute_received {:warehouse, _sql}
  end

  describe "with StarRocks enabled" do
    setup %{prev: prev} do
      enable_warehouse(prev, true)
      :ok
    end

    test "the trace page reads the trace and at most 256 hops from the warehouse" do
      assert {:ok, trace, [hop]} = MtrTrace.fetch_trace(@trace_id, nil, starrocks_query: detail_warehouse())

      assert_received {:warehouse, trace_sql}
      assert_received {:warehouse, hops_sql}
      assert trace_sql =~ "WHERE `id` = '#{@trace_id}'"
      refute trace_sql =~ "AND `time` >="
      assert hops_sql =~ "AND `time` >= '2026-01-01 12:00:00.000000'"
      assert hops_sql =~ "LIMIT 256"

      # The same keys trace_to_map/hop_to_map build from the Ash records.
      assert trace |> Map.keys() |> Enum.sort() == @trace_row |> Map.keys() |> Enum.sort()
      assert hop |> Map.keys() |> Enum.sort() == @hop_row |> Map.drop(["id", "time"]) |> Map.keys() |> Enum.sort()
      assert trace["time"] == ~U[2026-01-01 12:00:00.000000Z]
      assert trace["target_reached"] == true
      assert hop["ecmp_addrs"] == []
    end

    test "the trace page's hop sparklines read recent positive samples from the warehouse" do
      test = self()

      warehouse = fn sql ->
        send(test, {:warehouse, sql})

        {:ok,
         %{
           columns: ["addr", "time", "avg_us"],
           rows: [
             ["198.51.100.1", ~N[2026-01-01 12:02:00], 900],
             ["198.51.100.1", ~N[2026-01-01 12:01:00], 800]
           ]
         }}
      end

      hops = [%{"addr" => "198.51.100.1"}, %{"addr" => nil}, %{"addr" => ""}, %{"addr" => "198.51.100.1"}]

      assert %{"198.51.100.1" => points} = MtrTrace.hop_sparklines(hops, nil, starrocks_query: warehouse)
      assert points == [{~U[2026-01-01 12:01:00.000000Z], 800}, {~U[2026-01-01 12:02:00.000000Z], 900}]

      assert_received {:warehouse, sql}
      assert sql =~ "WHERE addr IN ('198.51.100.1')"
      assert sql =~ "AND avg_us IS NOT NULL"
      assert sql =~ "AND avg_us > 0"
      assert sql =~ ~r/AND `time` >= '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6}'/
      assert sql =~ "ORDER BY `time` DESC"
      assert sql =~ "LIMIT 200"
    end

    test "the Compare picker lists the newest 75 traces from the warehouse" do
      test = self()

      warehouse = fn sql ->
        send(test, {:warehouse, sql})

        columns = ~w(id time agent_id target target_ip target_reached total_hops protocol ip_version)
        row = [@trace_id, ~N[2026-01-01 12:00:00], "agent-01", "host01.example.com", nil, 0, 3, "icmp", 4]
        {:ok, %{columns: columns, rows: [row]}}
      end

      assert [trace] = MtrCompare.recent_traces(nil, starrocks_query: warehouse)
      assert trace["id"] == @trace_id
      assert trace["target_reached"] == false

      assert_received {:warehouse, sql}
      assert sql =~ "FROM serviceradar.mtr_traces"
      assert sql =~ ~r/WHERE `time` >= '\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6}'/
      assert sql =~ "ORDER BY `time` DESC\nLIMIT 75"

      failing = fn _sql -> {:error, :connect_failed} end
      assert MtrCompare.recent_traces(nil, starrocks_query: failing) == []
    end

    test "a Compare side reads its trace and hops from the warehouse, with the page's errors" do
      assert {:ok, trace, [hop]} = MtrCompare.load_trace_with_hops(@trace_id, nil, starrocks_query: detail_warehouse())

      assert trace |> Map.keys() |> Enum.sort() ==
               Enum.sort(~w(id time agent_id target target_ip target_reached total_hops protocol ip_version))

      assert hop |> Map.keys() |> Enum.sort() ==
               Enum.sort(~w(hop_number addr hostname asn asn_org loss_pct avg_us min_us max_us))

      assert_received {:warehouse, _trace_sql}
      assert_received {:warehouse, hops_sql}
      assert hops_sql =~ "LIMIT 256"

      assert {:error, "Invalid trace id"} = MtrCompare.load_trace_with_hops("not-a-uuid", nil)

      empty = fn _sql -> {:ok, %{columns: ["id"], rows: []}} end
      assert {:error, "Trace not found"} = MtrCompare.load_trace_with_hops(@trace_id, nil, starrocks_query: empty)
    end
  end
end
