defmodule ServiceRadar.Notifications.TimeZoneTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.Notifications.TimeZone
  alias ServiceRadar.TimeZone, as: NeutralTimeZone

  @now ~U[2026-08-11 14:00:00.000000Z]

  test "checks non-UTC names through PostgreSQL's installed catalog" do
    query = fn sql, params ->
      assert sql =~ "pg_timezone_names"
      assert params == ["America/New_York"]
      {:ok, %{rows: [[true]]}}
    end

    assert TimeZone.supported?("America/New_York", query: query)

    assert TimeZone.supported?("America/New_York", query: query) ==
             NeutralTimeZone.supported?("America/New_York", query: query)
  end

  test "does not accept a missing catalog name or an empty zone" do
    missing = fn _sql, ["Mars/Olympus_Mons"] -> {:ok, %{rows: [[false]]}} end

    refute TimeZone.supported?("Mars/Olympus_Mons", query: missing)
    refute TimeZone.supported?("", query: fn _, _ -> flunk("empty zone queried") end)
  end

  test "converts an instant with a parameterised AT TIME ZONE query" do
    query = fn sql, params ->
      assert sql =~ "$1::timestamptz AT TIME ZONE $2"
      assert params == [@now, "America/New_York"]
      {:ok, %{rows: [[~N[2026-08-11 10:00:00.000000]]]}}
    end

    assert TimeZone.local_datetime(@now, "America/New_York", query: query) ==
             NeutralTimeZone.local_datetime(@now, "America/New_York", query: query)

    assert TimeZone.local_datetime(@now, "America/New_York", query: query) ==
             {:ok, ~N[2026-08-11 10:00:00.000000]}
  end

  test "UTC aliases do not require a database lookup" do
    no_query = fn _, _ -> flunk("UTC alias queried") end

    assert TimeZone.local_datetime(@now, "utc", query: no_query) ==
             {:ok, ~N[2026-08-11 14:00:00.000000]}
  end
end
