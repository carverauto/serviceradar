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

  describe "window/2 resolves every form SRQL accepts" do
    @now ~U[2032-03-10 15:30:45Z]

    defp bounds(query), do: EventSummary.window(query, @now)

    test "relative tokens are case-insensitive and accept every unit spelling" do
      for {token, seconds} <- [
            {"LAST_24H", 86_400},
            {"last_15m", 900},
            {"last_2hours", 7200},
            {"last-3-days", 3 * 86_400},
            {"last_90d", 90 * 86_400},
            {"30min", 1800},
            {"last_0d", 0},
            {"Last_1Min", 60}
          ] do
        assert {^token, start_at, end_at} = bounds("in:events time:#{token}")
        assert end_at == @now
        assert DateTime.diff(end_at, start_at) == seconds
      end
    end

    test "a quoted spelled-out duration is carried as written" do
      assert {"last 2 days", start_at, end_at} = bounds(~s(in:events time:"last 2 days"))
      assert DateTime.diff(end_at, start_at) == 2 * 86_400
    end

    test "today runs from UTC midnight to now" do
      assert {"today", ~U[2032-03-10 00:00:00Z], @now} = bounds("in:events time:today")
      assert {"TODAY", ~U[2032-03-10 00:00:00Z], @now} = bounds("in:events time:TODAY")
    end

    test "yesterday is the previous UTC day" do
      assert {"yesterday", ~U[2032-03-09 00:00:00Z], ~U[2032-03-10 00:00:00Z]} = bounds("in:events time:yesterday")
    end

    test "an open-ended range runs to now" do
      assert {"[2032-03-05T00:00:00Z,]", ~U[2032-03-05 00:00:00Z], @now} =
               bounds("in:events time:[2032-03-05T00:00:00Z,]")
    end

    test "an open-start range reaches back ninety days" do
      assert {"[,2032-03-05T00:00:00Z]", start_at, ~U[2032-03-05 00:00:00Z]} =
               bounds("in:events time:[,2032-03-05T00:00:00Z]")

      assert DateTime.diff(~U[2032-03-05 00:00:00Z], start_at) == 90 * 86_400
    end

    test "a bracketed range accepts the space-separated UTC literal" do
      assert {_time, ~U[2032-03-01 00:00:00Z], ~U[2032-03-02 12:00:00Z]} =
               bounds("in:events time:[2032-03-01 00:00:00,2032-03-02 12:00:00]")
    end

    test "tokens SRQL rejects count the last seven days" do
      rejected = [
        "last_5x",
        "soon",
        "[,]",
        "[garbage,2032-03-05T00:00:00Z]",
        "last_99999999d",
        "[2032-03-11T00:00:00Z,]",
        "last_1y",
        "last_365d",
        "last_91d",
        "[2031-12-01T00:00:00Z,2032-03-10T00:00:00Z]"
      ]

      for token <- rejected do
        assert {"last_7d", start_at, end_at} = bounds("in:events time:#{token}")
        assert end_at == @now
        assert DateTime.diff(end_at, start_at) == 7 * 86_400
      end
    end
  end

  test "a card link quotes a window token that contains spaces" do
    assert EventSummary.severity_query("High", "last 2 days") ==
             ~s(in:events severity:High time:"last 2 days" sort:time:desc)
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
