defmodule ServiceRadarWebNGWeb.SRQL.TimeWindowTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.SRQL.TimeWindow

  test "extracts normalized time tokens from queries" do
    assert TimeWindow.token_from_query("in:flows time:last_24h limit:10") == "last_24h"
    assert TimeWindow.token_from_query("in:flows time:24h limit:10") == "last_24h"
  end

  test "ignores time-looking tokens inside quoted strings" do
    query = ~s|in:logs message:"time:last_1h inside body" time:last_7d sort:timestamp:desc|

    assert TimeWindow.token_from_query(query) == "last_7d"
    assert TimeWindow.token_from_query(~s|in:logs message:"time:last_1h inside body"|, "last_24h") == "last_24h"
  end

  test "resolves relative time windows against a supplied clock" do
    now = ~U[2026-06-19 12:00:00Z]

    assert {:ok, %{start: ~U[2026-06-19 06:00:00Z], end: ^now}} = TimeWindow.resolve("last_6h", now)
    assert TimeWindow.seconds("last_6h") == 21_600
  end

  test "resolves bracketed absolute windows" do
    token = "[2026-06-19T10:00:00Z,2026-06-19T12:30:00Z]"

    assert {:ok, %{start: ~U[2026-06-19 10:00:00Z], end: ~U[2026-06-19 12:30:00Z]}} =
             TimeWindow.resolve(token)

    assert TimeWindow.seconds(token) == 9_000
  end

  test "falls back for unsupported windows" do
    assert TimeWindow.token_from_query("in:flows sort:timestamp:desc", "last_1h") == "last_1h"
    assert TimeWindow.seconds("not-a-window", 42) == 42
    assert TimeWindow.preset_seconds("unknown") == 3_600
  end
end
