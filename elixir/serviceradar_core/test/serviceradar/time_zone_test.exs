defmodule ServiceRadar.TimeZoneTest do
  use ExUnit.Case, async: true

  alias ServiceRadar.TimeZone

  test "normalizes UTC aliases and rejects non-profile timezone syntax" do
    for alias_name <- ["UTC", " utc ", "GMT", "Etc/GMT", "Z", "Zulu", "Etc/Zulu"] do
      assert TimeZone.normalize_preference(alias_name) == {:ok, "Etc/UTC"}
    end

    for invalid <- [nil, "", "   ", "CST", "+05:00", "Etc/GMT+5", "posix/America/Chicago"] do
      assert TimeZone.normalize_preference(invalid) == {:error, :invalid_timezone}
    end
  end

  test "reads a sorted finite profile catalog from PostgreSQL without parameters" do
    catalog_query = fn sql, params ->
      assert sql =~ "pg_timezone_names"
      assert params == []

      {:ok, %{rows: [["America/Chicago"], ["CST"], ["Etc/GMT+5"], ["posix/Europe/London"]]}}
    end

    assert TimeZone.profile_timezones(query: catalog_query) ==
             {:ok, ["America/Chicago", "Etc/UTC"]}
  end

  test "returns only canonical Etc/UTC for UTC catalog aliases" do
    catalog_query = fn _, _ ->
      {:ok, %{rows: [["Etc/GMT"], ["Etc/UTC"], ["Etc/Zulu"], ["America/Chicago"]]}}
    end

    assert TimeZone.profile_timezones(query: catalog_query) ==
             {:ok, ["America/Chicago", "Etc/UTC"]}
  end

  test "reports an unavailable PostgreSQL timezone catalog" do
    assert TimeZone.profile_timezones(query: fn _, _ -> {:error, :catalog_unavailable} end) ==
             {:error, :catalog_unavailable}
  end

  test "profile picker zones keep a single Etc/UTC first even when extras and catalog repeat it" do
    assert TimeZone.profile_picker_zones(
             ["Etc/UTC", "America/Chicago", "Etc/UTC"],
             ["Etc/UTC", "Legacy/Removed", ""]
           ) == ["Etc/UTC", "America/Chicago", "Legacy/Removed"]
  end

  test "requires normalized profile timezone names to be catalog members" do
    query = fn _, _ -> {:ok, %{rows: [["America/Chicago"]]}} end

    assert TimeZone.validate_preference(" America/Chicago ", query: query) ==
             {:ok, "America/Chicago"}

    assert TimeZone.validate_preference("America/New_York", query: query) ==
             {:error, :invalid_timezone}
  end
end
