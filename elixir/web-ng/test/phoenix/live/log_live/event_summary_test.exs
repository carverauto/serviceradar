defmodule ServiceRadarWebNGWeb.LogLive.EventSummaryTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.LogLive.EventSummary

  @moduletag :db_free

  test "counts the absolute range the query lists, not the last seven days" do
    query = "in:events time:[2032-03-01T00:00:00Z,2032-03-08T00:00:00Z] sort:time:desc limit:20"

    sql_query = fn sql, params ->
      assert params == [~U[2032-03-01 00:00:00Z], ~U[2032-03-08 00:00:00Z], 21_600]
      # Hours the short-retention rollup no longer holds come from raw events.
      assert sql =~ "rollup_start >= rollup_end OR time < rollup_start OR time >= rollup_end"

      {:ok,
       %{rows: [[~U[2032-03-02 00:00:00Z], 5, 40], [~U[2032-03-02 00:00:00Z], 6, 2], [~U[2032-03-07 18:00:00Z], 3, 9]]}}
    end

    summary = EventSummary.load(query, query: sql_query)

    assert summary.critical == 42
    assert summary.medium == 9
    assert summary.total == 51
    assert summary.time == "[2032-03-01T00:00:00Z,2032-03-08T00:00:00Z]"
  end

  test "a relative window is counted and carried as written" do
    {time, start_at, end_at} = EventSummary.window("in:events severity:High time:last_30d")

    assert time == "last_30d"
    assert DateTime.diff(end_at, start_at) == 30 * 86_400
  end

  test "a query without a usable time counts the last seven days" do
    for query <- [nil, "in:events sort:time:desc", "in:events time:[2032-03-08T00:00:00Z,2032-03-01T00:00:00Z]"] do
      {time, start_at, end_at} = EventSummary.window(query)

      assert time == "last_7d"
      assert DateTime.diff(end_at, start_at) == 7 * 86_400
    end
  end

  test "a card links to the window it counted" do
    assert EventSummary.severity_query("Critical", "[2032-03-01T00:00:00Z,2032-03-08T00:00:00Z]") ==
             "in:events severity:Critical time:[2032-03-01T00:00:00Z,2032-03-08T00:00:00Z] sort:time:desc"

    assert EventSummary.severity_query("High", "last_7d") == "in:events severity:High time:last_7d sort:time:desc"
  end

  test "a failed load shows empty cards that still link to the counted window" do
    summary = EventSummary.load("in:events time:last_24h", query: fn _sql, _params -> {:error, :query_failed} end)

    assert summary == %{EventSummary.empty() | time: "last_24h"}
  end
end
