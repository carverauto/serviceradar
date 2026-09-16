defmodule ServiceRadarWebNGWeb.LogLive.NetflowSummaryTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.LogLive.NetflowSummary

  @moduletag :db_free
  @scope %{permissions: MapSet.new(["observability.netflow.view"])}

  test "whole-window totals ignore the explorer limit and use canonical sampled packet totals" do
    responses([
      [%{"total" => 1200}],
      [%{"total_bytes" => 604_800_000}],
      [%{"total_packets" => 604_800}],
      [%{"protocol_num" => 6, "total" => 900}, %{"protocol_num" => 17, "total" => 200}]
    ])

    assert {:ok, summary} =
             NetflowSummary.load(
               __MODULE__,
               "in:flows time:last_7d src_ip:192.0.2.8 limit:50 sort:time:desc",
               @scope,
               true
             )

    assert summary.total == 1200
    assert summary.tcp == 900
    assert summary.udp == 200
    assert summary.other == 100
    assert summary.total_packets == 604_800
    assert summary.avg_pps == 1.0
    assert summary.avg_bps == 8000.0
    assert summary.window_seconds == 7 * 86_400

    for _ <- 1..4 do
      assert_receive {:query, query, %{scope: @scope}}
      assert query =~ "time:last_7d"
      assert query =~ "src_ip:192.0.2.8"
      refute query =~ "limit:50"
      refute query =~ "sort:time:desc"
      refute query =~ "sum(packets)"
      refute query =~ "packets_in"

      if query =~ "by protocol_num" do
        assert query =~ "proto:(6,17)"
        assert query =~ "limit:2"
      else
        refute query =~ "proto:(6,17)"
      end
    end

    refute_receive {:query, _, _}
  end

  test "protocol breakdown narrows existing filters and keeps other-only traffic in the scalar total" do
    responses([[%{"total" => 8}], [%{"total_bytes" => 800}], [%{"total_packets" => 8}], []])

    assert {:ok, %{total: 8, tcp: 0, udp: 0, other: 8}} =
             NetflowSummary.load(__MODULE__, "in:flows time:last_7d proto:1", @scope)

    for _ <- 1..4 do
      assert_receive {:query, query, %{scope: @scope}}
      assert query =~ "proto:1"

      if query =~ "by protocol_num", do: assert(query =~ "proto:(6,17)")
    end
  end

  test "empty materialized totals with real page observations fail instead of reporting the page size" do
    responses([[%{"total" => nil}], [%{"total_bytes" => nil}], [%{"total_packets" => nil}], []])
    assert {:error, :netflow_summary_incomplete} = NetflowSummary.load(__MODULE__, "in:flows time:last_30d", @scope, true)
  end

  test "protocol counts expose incomplete traffic aggregates even when the explorer page is empty" do
    responses([
      [%{"total" => nil}],
      [%{"total_bytes" => nil}],
      [%{"total_packets" => nil}],
      [%{"protocol_num" => 6, "total" => 100}]
    ])

    assert {:error, :netflow_summary_incomplete} = NetflowSummary.load(__MODULE__, "in:flows time:last_30d", @scope)
  end

  test "a genuinely empty window remains zero and a thirty-day denominator is preserved" do
    responses([[%{"total" => 0}], [%{"total_bytes" => nil}], [%{"total_packets" => nil}], []])

    assert {:ok, %{total: 0, avg_bps: avg_bps, window_seconds: seconds}} =
             NetflowSummary.load(__MODULE__, "in:flows time:last_30d", @scope)

    assert avg_bps == 0.0
    assert seconds == 30 * 86_400
  end

  test "query failure stops further queries and remains an explicit failure" do
    Process.put(:responses, [{:error, :synthetic_unavailable}])
    assert {:error, :netflow_summary_unavailable} = NetflowSummary.load(__MODULE__, "in:flows time:last_7d", @scope)
    assert_receive {:query, _, _}
    refute_receive {:query, _, _}
  end

  test "malformed aggregate values cannot masquerade as zero" do
    responses([[%{"total" => "not-a-count"}]])
    assert {:error, :invalid_netflow_summary} = NetflowSummary.load(__MODULE__, "in:flows time:last_7d", @scope)
  end

  def query(query, opts) do
    send(self(), {:query, query, opts})
    [response | rest] = Process.get(:responses)
    Process.put(:responses, rest)
    response
  end

  defp responses(rows), do: Process.put(:responses, Enum.map(rows, &{:ok, %{"results" => &1}}))
end
