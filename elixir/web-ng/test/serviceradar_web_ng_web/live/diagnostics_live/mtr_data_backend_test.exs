defmodule ServiceRadarWebNGWeb.DiagnosticsLive.MtrDataBackendTest do
  # Not async: the StarRocks switch is global application env.
  use ExUnit.Case, async: false

  alias ServiceRadar.Analytics.StarRocks
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrData
  alias ServiceRadarWebNGWeb.DiagnosticsLive.MtrWarehouse

  @moduletag :db_free

  # Every value below is synthetic: documentation address ranges, invented ids.
  @trace_id "0b7c6f36-2f6e-4d0c-9a51-3c1d8e2f4a10"
  @trace_time ~U[2026-01-01 12:00:00.250000Z]

  @list_columns ~w(
    id time agent_id check_id check_name device_id target target_ip target_reached total_hops
    probed_hops last_responding_hop protocol tcp_port ip_version error destination_sent
    destination_received destination_avg_us destination_loss_pct
  )

  setup do
    prev = Application.get_env(:serviceradar_core, StarRocks, [])
    on_exit(fn -> Application.put_env(:serviceradar_core, StarRocks, prev) end)
    %{prev: prev}
  end

  defp enable_warehouse(prev, enabled?) do
    # The per-dataset cutover list is deliberately left empty: MTR keys on the
    # global switch alone.
    Application.put_env(
      :serviceradar_core,
      StarRocks,
      prev |> Keyword.put(:enabled, enabled?) |> Keyword.put(:cutover_datasets, [])
    )
  end

  # A CNPG seam that records the statement and answers with an empty result.
  defp cnpg_recorder(columns \\ ["trace_count"]) do
    test = self()

    fn sql, params ->
      send(test, {:cnpg, sql, params})

      if sql =~ "COUNT(*)::bigint AS total" do
        {:ok, %{columns: ["total"], rows: [[0]]}}
      else
        {:ok, %{columns: columns, rows: []}}
      end
    end
  end

  defp warehouse_forbidden do
    test = self()

    fn sql ->
      send(test, {:warehouse, sql})
      {:error, :warehouse_must_not_be_queried}
    end
  end

  defp cnpg_forbidden do
    test = self()

    fn sql, _params ->
      send(test, {:cnpg, sql, :forbidden})
      {:error, :cnpg_must_not_be_queried}
    end
  end

  describe "with StarRocks disabled" do
    setup %{prev: prev} do
      enable_warehouse(prev, false)
      :ok
    end

    test "the paginated list runs the CNPG where-clause and parameters it always ran" do
      assert {:ok, %{rows: [], total_count: 0, page: 2, per_page: 25}} =
               MtrData.list_traces_paginated(
                 target_filter: "core",
                 agent_filter: "edge",
                 device_uid: "sr:device-01",
                 device_ip: "192.0.2.10",
                 srql_query:
                   "in:mtr_traces time:[2026-01-01T00:00:00Z,2026-01-02T00:00:00Z] protocol:tcp " <>
                     "target_reached:true check_name:ping device_id:sr:device-02 sort:target:asc probe",
                 page: 2,
                 limit: 25,
                 cnpg_query: cnpg_recorder(),
                 starrocks_query: warehouse_forbidden()
               )

      assert_received {:cnpg, page_sql, page_params}
      assert_received {:cnpg, count_sql, count_params}
      refute_received {:warehouse, _sql}

      where =
        "WHERE (target ILIKE $1 OR target_ip ILIKE $1) AND agent_id ILIKE $2 AND " <>
          "(device_id::text = $3 OR target_ip = $4) AND time >= $5 AND time < $6 AND " <>
          "protocol = $7 AND target_reached = $8 AND check_name ILIKE $9 AND device_id::text = $10 AND " <>
          "(target ILIKE $11 OR target_ip ILIKE $11 OR agent_id ILIKE $11 OR check_name ILIKE $11)"

      assert page_sql =~ where
      assert page_sql =~ "FROM mtr_traces"
      assert page_sql =~ "ORDER BY target ASC, time ASC, id ASC"
      assert page_sql =~ "LIMIT $12"
      assert page_sql =~ "OFFSET $13"
      assert count_sql =~ where

      filter_params = [
        "%core%",
        "%edge%",
        "sr:device-01",
        "192.0.2.10",
        ~U[2026-01-01 00:00:00Z],
        ~U[2026-01-02 00:00:00Z],
        "tcp",
        true,
        "%ping%",
        "sr:device-02",
        "%probe%"
      ]

      assert page_params == filter_params ++ [25, 25]
      assert count_params == filter_params
    end

    test "list, coverage, detail and Compare read CNPG and never the warehouse" do
      assert {:ok, []} =
               MtrData.list_traces(
                 device_ip: "192.0.2.10",
                 cnpg_query: cnpg_recorder(@list_columns),
                 starrocks_query: warehouse_forbidden()
               )

      assert_received {:cnpg, list_sql, ["192.0.2.10", 50]}
      assert list_sql =~ "WHERE target_ip = $1"
      assert list_sql =~ "FROM mtr_hops h"

      coverage_query = fn sql, params ->
        send(self(), {:cnpg, sql, params})
        {:ok, %{columns: [], rows: [[0, 0, 0, nil, nil]]}}
      end

      assert {:ok, %{trace_count: 0}} =
               MtrData.trace_coverage(
                 agent_filter: "edge",
                 cnpg_query: coverage_query,
                 starrocks_query: warehouse_forbidden()
               )

      assert_received {:cnpg, coverage_sql, ["%edge%"]}
      assert coverage_sql =~ "COUNT(*) FILTER (WHERE target_reached)"

      assert {:error, :not_found} =
               MtrData.get_trace_detail(%{}, @trace_id,
                 cnpg_query: cnpg_recorder(),
                 starrocks_query: warehouse_forbidden()
               )

      assert_received {:cnpg, detail_sql, [_uuid_binary]}
      assert detail_sql =~ "FROM mtr_traces"

      compare_query = fn sql, params ->
        send(self(), {:cnpg, sql, params})

        if sql =~ "avg_destination_us" do
          {:ok, %{columns: [], rows: [[0, 0, 0, 0.0, nil, nil, 0, 0, 0]]}}
        else
          {:ok, %{columns: [], rows: []}}
        end
      end

      assert {:ok, %{a: %{trace_count: 0}}} =
               MtrData.compare_windows(
                 window_a: %{start: ~U[2026-01-02 00:00:00Z], end: ~U[2026-01-03 00:00:00Z]},
                 window_b: %{start: ~U[2026-01-01 00:00:00Z], end: ~U[2026-01-02 00:00:00Z]},
                 protocol: "icmp",
                 reached: "reached",
                 cnpg_query: compare_query,
                 starrocks_query: warehouse_forbidden()
               )

      assert_received {:cnpg, summary_sql, [_start, _end, "icmp", true]}
      assert summary_sql =~ "AND t.protocol = $3 AND t.target_reached = $4"
      refute_received {:warehouse, _sql}
    end
  end

  describe "with StarRocks enabled" do
    setup %{prev: prev} do
      enable_warehouse(prev, true)
      :ok
    end

    test "the trace list reads the warehouse and shapes rows like CNPG's" do
      warehouse = fn sql ->
        send(self(), {:warehouse, sql})

        {:ok,
         %{
           columns: @list_columns,
           rows: [
             [
               @trace_id,
               ~N[2026-01-01 12:00:00.250000],
               "agent-01",
               "check-01",
               "ping",
               "sr:device-01",
               "host01.example.com",
               "192.0.2.10",
               1,
               4,
               4,
               4,
               "icmp",
               nil,
               4,
               nil,
               10,
               8,
               2_500,
               Decimal.new("20.0")
             ]
           ]
         }}
      end

      assert {:ok, [trace]} =
               MtrData.list_traces(
                 target_filter: "host01",
                 device_uid: "sr:device-01",
                 limit: 20,
                 cnpg_query: cnpg_forbidden(),
                 starrocks_query: warehouse
               )

      refute_received {:cnpg, _sql, _params}
      assert_received {:warehouse, sql}

      assert sql =~ "FROM serviceradar.mtr_traces"
      assert sql =~ "FROM serviceradar.mtr_hops h"
      refute sql =~ "platform."
      refute sql =~ "ILIKE"
      refute sql =~ "::"
      refute sql =~ "FILTER ("

      assert sql =~
               "WHERE (LOWER(`target`) LIKE LOWER('%host01%') OR LOWER(`target_ip`) LIKE LOWER('%host01%')) " <>
                 "AND `device_id` = 'sr:device-01'"

      assert sql =~ "LIMIT 20"
      # The #4625 bounds: a hop is never older than its trace, and the hop scan
      # starts at the oldest selected trace.
      assert sql =~ "AND h.`time` >= st.`time`"
      assert sql =~ "WHERE h.`time` >= (SELECT MIN(`time`) FROM selected_traces)"
      assert sql =~ "ORDER BY h.`time` DESC, h.`id` DESC"

      assert trace["id"] == @trace_id
      assert trace["time"] == @trace_time
      assert trace["target_reached"] == true
      assert trace["destination_loss_pct"] == 20.0
      assert %{latency: [{@trace_time, 2_500}]} = MtrData.build_trends([trace])
    end

    test "the paginated list renders the same terms for the warehouse and orders NULLs like Postgres" do
      test = self()

      warehouse = fn sql ->
        send(test, {:warehouse, sql})

        if sql =~ "COUNT(*) AS total" do
          {:ok, %{columns: ["total"], rows: [[41]]}}
        else
          {:ok, %{columns: ["id", "time"], rows: [[@trace_id, "2026-01-01 12:00:00.25"]]}}
        end
      end

      assert {:ok, %{rows: [row], total_count: 41, page: 2, per_page: 25}} =
               MtrData.list_traces_paginated(
                 agent_filter: "edge",
                 srql_query:
                   "in:mtr_traces time:[2026-01-01T00:00:00Z,2026-01-02T00:00:00Z] protocol:tcp " <>
                     "target_reached:false sort:target:asc probe",
                 page: 2,
                 limit: 25,
                 cnpg_query: cnpg_forbidden(),
                 starrocks_query: warehouse
               )

      assert row["time"] == @trace_time
      refute_received {:cnpg, _sql, _params}
      assert_received {:warehouse, page_sql}
      assert_received {:warehouse, count_sql}

      where =
        "WHERE LOWER(`agent_id`) LIKE LOWER('%edge%') AND `time` >= '2026-01-01 00:00:00' AND " <>
          "`time` < '2026-01-02 00:00:00' AND `protocol` = 'tcp' AND `target_reached` = FALSE AND " <>
          "(LOWER(`target`) LIKE LOWER('%probe%') OR LOWER(`target_ip`) LIKE LOWER('%probe%') OR " <>
          "LOWER(`agent_id`) LIKE LOWER('%probe%') OR LOWER(`check_name`) LIKE LOWER('%probe%'))"

      assert page_sql =~ where
      assert page_sql =~ "ORDER BY `target` ASC NULLS LAST, `time` ASC, `id` ASC"
      assert page_sql =~ "LIMIT 25 OFFSET 25"
      assert count_sql =~ "SELECT COUNT(*) AS total"
      assert count_sql =~ where
    end

    test "a descending sort puts NULLs first, as Postgres does" do
      warehouse = fn sql ->
        send(self(), {:warehouse, sql})
        if sql =~ "COUNT(*)", do: {:ok, %{columns: ["total"], rows: [[0]]}}, else: {:ok, %{columns: [], rows: []}}
      end

      assert {:ok, _page} =
               MtrData.list_traces_paginated(
                 srql_query: "sort:total_hops:desc",
                 limit: 10,
                 starrocks_query: warehouse
               )

      assert_received {:warehouse, page_sql}
      assert page_sql =~ "ORDER BY `total_hops` DESC NULLS FIRST, `time` DESC, `id` DESC"
    end

    test "filter values are escaped, and a value CNPG would reject is refused before any query" do
      warehouse = fn sql ->
        send(self(), {:warehouse, sql})
        {:ok, %{columns: [], rows: [[0, 0, 0, nil, nil]]}}
      end

      assert {:ok, _coverage} =
               MtrData.trace_coverage(target_filter: "a'b\\c", starrocks_query: warehouse)

      assert_received {:warehouse, sql}
      assert sql =~ "LOWER(`target`) LIKE LOWER('%a\\'b\\\\c%')"
      assert sql =~ "COUNT(CASE WHEN target_reached THEN 1 END) AS reached_count"
      assert sql =~ "COUNT(CASE WHEN NOT target_reached THEN 1 END) AS failed_count"

      assert {:error, :invalid_filter_value} =
               MtrData.trace_coverage(agent_filter: "edge" <> <<0>>, starrocks_query: warehouse)

      assert {:error, :invalid_filter_value} =
               MtrData.list_traces(target_filter: "host" <> <<0>> <> "01", starrocks_query: warehouse)

      refute_received {:warehouse, _sql}
    end

    test "trace detail reads the trace, then its hops bounded by the trace's time" do
      test = self()

      warehouse = fn sql ->
        send(test, {:warehouse, sql})

        cond do
          sql =~ "FROM serviceradar.mtr_traces" ->
            {:ok,
             %{
               columns: ["id", "time", "target", "target_reached", "tcp_syn_drop_pct"],
               rows: [[@trace_id, ~N[2026-01-01 12:00:00.250000], "host01.example.com", 0, Decimal.new("12.5")]]
             }}

          sql =~ "FROM serviceradar.mtr_hops" ->
            {:ok,
             %{
               columns: ["id", "time", "hop_number", "addr", "ecmp_addrs", "mpls_labels", "avg_us"],
               rows: [
                 [
                   "hop-01",
                   ~N[2026-01-01 12:00:01],
                   1,
                   "192.0.2.1",
                   ~s(["192.0.2.1","192.0.2.2"]),
                   ~s({"labels":[{"label":16001,"exp":0,"s":1,"ttl":64}]}),
                   900
                 ]
               ]
             }}
        end
      end

      assert {:ok, trace, [hop]} =
               MtrData.get_trace_detail(%{}, @trace_id,
                 time: @trace_time,
                 cnpg_query: cnpg_forbidden(),
                 starrocks_query: warehouse
               )

      refute_received {:cnpg, _sql, _params}
      assert_received {:warehouse, trace_sql}
      assert_received {:warehouse, hops_sql}

      assert trace_sql =~ "WHERE `id` = '#{@trace_id}'"
      # The caller's time bounds the lookup to the second holding it.
      assert trace_sql =~ "AND `time` >= '2026-01-01 12:00:00' AND `time` < '2026-01-01 12:00:01'"
      assert trace_sql =~ "`partition`"
      assert trace_sql =~ "`tcp_server_response_us`"

      assert hops_sql =~ "WHERE trace_id = '#{@trace_id}' AND `time` >= '2026-01-01 12:00:00.250000'"
      assert hops_sql =~ "ORDER BY hop_number ASC, `time` DESC, `id` DESC"
      refute hops_sql =~ "LIMIT"

      assert trace["time"] == @trace_time
      assert trace["target_reached"] == false
      assert trace["tcp_syn_drop_pct"] == 12.5
      assert hop["time"] == ~U[2026-01-01 12:00:01.000000Z]
      assert hop["ecmp_addrs"] == ["192.0.2.1", "192.0.2.2"]
      assert hop["mpls_labels"] == %{"labels" => [%{"label" => 16_001, "exp" => 0, "s" => 1, "ttl" => 64}]}
    end

    test "trace detail keeps CNPG's id and scope handling" do
      assert {:error, :missing_scope} = MtrData.get_trace_detail(nil, @trace_id, starrocks_query: warehouse_forbidden())

      assert {:error, :not_found} =
               MtrData.get_trace_detail(%{}, "not-a-uuid", starrocks_query: warehouse_forbidden())

      refute_received {:warehouse, _sql}

      empty = fn _sql -> {:ok, %{columns: ["id"], rows: []}} end
      assert {:error, :not_found} = MtrData.get_trace_detail(%{}, @trace_id, starrocks_query: empty)
    end

    test "Compare windows read the warehouse with the window bounds and shape every panel" do
      test = self()

      warehouse = fn sql ->
        send(test, {:warehouse, sql})

        cond do
          sql =~ "hop_depth AS" ->
            {:ok,
             %{
               columns: ~w(trace_count reached_count failed_count avg_hops avg_destination_us
                 destination_loss_pct endpoint_sample_count agent_count target_count),
               rows: [[10, 8, 2, 4.25, 1_500.0, 12.5, 8, 2, 3]]
             }}

          sql =~ "WITH buckets AS" ->
            {:ok,
             %{
               columns: ~w(bucket_start bucket_end trace_count reached_count failed_count),
               rows: [["2026-01-02 00:00:00", "2026-01-02 01:00:00", 3, 2, 1]]
             }}

          sql =~ "signature_id" ->
            {:ok,
             %{
               columns: ~w(signature_id path_preview trace_count reached_count agent_count
                 representative_trace_id latest_time agent_ids),
               rows: [
                 [
                   "0cc175b9c0f1b6a831c399e269772661",
                   "192.0.2.1 -> *",
                   4,
                   3,
                   2,
                   @trace_id,
                   ~N[2026-01-02 00:30:00],
                   ~s(["agent-01","agent-02"])
                 ]
               ]
             }}

          sql =~ "a_trace_count" ->
            {:ok,
             %{
               columns: ~w(agent_id a_trace_count a_reached_count b_trace_count b_reached_count),
               rows: [["agent-01", 4, 3, 2, 2]]
             }}
        end
      end

      assert {:ok, comparison} =
               MtrData.compare_windows(
                 window_a: %{start: ~U[2026-01-02 00:00:00Z], end: ~U[2026-01-03 00:00:00Z], label: "Today"},
                 window_b: %{start: ~U[2026-01-01 00:00:00Z], end: ~U[2026-01-02 00:00:00Z], label: "Yesterday"},
                 target_filter: "host01",
                 agent_filter: "agent",
                 protocol: "tcp",
                 reached: "unreachable",
                 bucket_count: 24,
                 signature_limit: 6,
                 cnpg_query: cnpg_forbidden(),
                 starrocks_query: warehouse
               )

      refute_received {:cnpg, _sql, _params}

      assert comparison.a.trace_count == 10
      assert comparison.a.success_rate == 80.0
      assert comparison.a.avg_hops == 4.3
      assert comparison.a.avg_destination_us == 1_500.0
      assert comparison.deltas.trace_count == 0
      assert [%{"bucket_start" => ~U[2026-01-02 00:00:00.000000Z], "trace_count" => 3}] = comparison.a.timeline

      assert [%{"agent_ids" => ["agent-01", "agent-02"], "latest_time" => ~U[2026-01-02 00:30:00.000000Z]}] =
               comparison.a.route_signatures

      assert [%{"agent_id" => "agent-01", "a_success_rate" => 75.0, "b_success_rate" => 100.0}] = comparison.agents

      sqls = collect_warehouse_sql()
      assert length(sqls) == 7

      filters =
        "AND (LOWER(t.`target`) LIKE LOWER('%host01%') OR LOWER(t.`target_ip`) LIKE LOWER('%host01%')) " <>
          "AND LOWER(t.`agent_id`) LIKE LOWER('%agent%') AND t.`protocol` = 'tcp' AND t.`target_reached` = FALSE"

      for sql <- sqls do
        assert sql =~ filters
        refute sql =~ "FILTER ("
        refute sql =~ "::"
        refute sql =~ "generate_series"
        refute sql =~ "platform."
      end

      [summary_a | _] = Enum.filter(sqls, &(&1 =~ "hop_depth AS"))
      assert summary_a =~ "WHERE t.`time` >= '2026-01-02 00:00:00' AND t.`time` < '2026-01-03 00:00:00'"
      # Terminal hops keep CNPG's window bounds; the depth scan keeps its lower bound only.
      assert summary_a =~ "WHERE h.`time` >= '2026-01-02 00:00:00' AND h.`time` < '2026-01-03 00:00:00'"
      assert summary_a =~ "AND h.`time` >= st.`time`"
      assert summary_a =~ "COALESCE(st.last_responding_hop, hd.responding_depth, st.total_hops)"
      assert summary_a =~ "COALESCE(MAX(CASE WHEN h.received > 0 THEN h.hop_number END), 0) AS responding_depth"

      [timeline_a | _] = Enum.filter(sqls, &(&1 =~ "WITH buckets AS"))
      assert timeline_a =~ "SELECT 0 AS idx, CAST('2026-01-02 00:00:00.000000' AS DATETIME) AS bucket_start"
      assert timeline_a =~ "SELECT 23 AS idx, CAST('2026-01-02 23:00:00.000000' AS DATETIME) AS bucket_start"
      assert timeline_a =~ "WHERE t.`time` >= '2026-01-02 00:00:00.000000' AND t.`time` < '2026-01-03 00:00:00.000000'"

      [signatures_a | _] = Enum.filter(sqls, &(&1 =~ "signature_id"))
      assert signatures_a =~ "array_agg(COALESCE(NULLIF(h.addr, ''), '*') ORDER BY h.hop_number) AS hop_addrs"
      assert signatures_a =~ "array_join(hop_addrs, '>')"
      assert signatures_a =~ "element_at(array_agg(trace_id ORDER BY `time` DESC), 1)"
      assert signatures_a =~ "LIMIT 6"

      [agents] = Enum.filter(sqls, &(&1 =~ "a_trace_count"))
      assert agents =~ "WHEN t.`time` >= '2026-01-02 00:00:00' AND t.`time` < '2026-01-03 00:00:00' THEN 'a'"
      assert agents =~ "WHEN t.`time` >= '2026-01-01 00:00:00' AND t.`time` < '2026-01-02 00:00:00' THEN 'b'"
    end

    test "timeline buckets follow CNPG's step, including its one-second floor and overshoot" do
      day = MtrWarehouse.timeline_buckets(~U[2026-01-01 00:00:00Z], ~U[2026-01-02 00:00:00Z], 24)
      assert length(day) == 24
      assert {0, ~U[2026-01-01 00:00:00.000000Z], ~U[2026-01-01 01:00:00.000000Z]} = hd(day)
      assert {23, ~U[2026-01-01 23:00:00.000000Z], ~U[2026-01-02 00:00:00.000000Z]} = List.last(day)

      # 1000 s / 24 rounds to the microsecond, as interval division does.
      [_first, {1, second_start, _end} | _rest] =
        MtrWarehouse.timeline_buckets(~U[2026-01-01 00:00:00Z], ~U[2026-01-01 00:16:40Z], 24)

      assert DateTime.diff(second_start, ~U[2026-01-01 00:00:00Z], :microsecond) == 41_666_667

      # A 10 s window cut into 24 buckets steps by the one-second floor, so the
      # buckets, and the traces they count, run past the window's end.
      short = MtrWarehouse.timeline_buckets(~U[2026-01-01 00:00:00Z], ~U[2026-01-01 00:00:10Z], 24)
      assert {23, _start, ~U[2026-01-01 00:00:24.000000Z]} = List.last(short)
    end
  end

  defp collect_warehouse_sql(acc \\ []) do
    receive do
      {:warehouse, sql} -> collect_warehouse_sql([sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
