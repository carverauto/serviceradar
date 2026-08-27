defmodule ServiceRadarWebNGWeb.DashboardLive.EventRangeTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DashboardLive.EventRange

  @moduletag :db_free

  test "builds canonical rendered bucket boundaries from UTC and naive hourly points" do
    points = [
      %{bucket: ~U[2026-08-27 10:00:00Z]},
      %{bucket: ~N[2026-08-27 12:00:00]},
      %{bucket: ~U[2026-08-27 13:00:00Z]}
    ]

    assert {:ok,
            [
              %{x: 36, start: "2026-08-27T10:00:00Z", end: "2026-08-27T10:59:59.999999Z"},
              %{x: 326, start: "2026-08-27T12:00:00Z", end: "2026-08-27T12:59:59.999999Z"},
              %{x: 616, start: "2026-08-27T13:00:00Z", end: "2026-08-27T13:59:59.999999Z"}
            ]} = EventRange.buckets(points)
  end

  test "keeps a one-point chart selectable at the plot origin" do
    assert {:ok,
            [
              %{x: 36, start: "2026-08-27T10:00:00Z", end: "2026-08-27T10:59:59.999999Z"}
            ]} = EventRange.buckets([%{bucket: ~U[2026-08-27 10:00:00Z]}])
  end

  test "rejects empty, non-list, and partially invalid trend data" do
    assert :error = EventRange.buckets([])
    assert :error = EventRange.buckets(%{bucket: ~U[2026-08-27 10:00:00Z]})
    assert :error = EventRange.buckets([%{bucket: ~U[2026-08-27 10:00:00Z]}, %{}])
    assert :error = EventRange.buckets([%{bucket: "2026-08-27T12:00:00Z"}])
  end

  test "returns parsed UTC times for an exact rendered selection across a missing wall-clock hour" do
    assert {:ok, {~U[2026-08-27 10:00:00Z], ~U[2026-08-27 12:59:59.999999Z]}} =
             EventRange.selection(points(), %{
               "start" => "2026-08-27T10:00:00Z",
               "end" => "2026-08-27T12:59:59.999999Z"
             })
  end

  test "rejects malformed, equal, reversed, non-rendered, stale, and offset-equivalent selections" do
    for params <- [
          %{"start" => "bad", "end" => "2026-08-27T12:59:59.999999Z"},
          %{"start" => "2026-08-27T10:00:00Z", "end" => "2026-08-27T10:00:00Z"},
          %{"start" => "2026-08-27T12:00:00Z", "end" => "2026-08-27T10:59:59.999999Z"},
          %{"start" => "2026-08-27T10:30:00Z", "end" => "2026-08-27T12:59:59.999999Z"},
          %{"start" => "2026-08-27T09:00:00Z", "end" => "2026-08-27T09:59:59.999999Z"},
          %{"start" => "2026-08-27T05:00:00-05:00", "end" => "2026-08-27T07:59:59.999999-05:00"}
        ] do
      assert :error = EventRange.selection(points(), params)
    end
  end

  defp points do
    [
      %{bucket: ~U[2026-08-27 10:00:00Z]},
      %{bucket: ~N[2026-08-27 12:00:00]},
      %{bucket: ~U[2026-08-27 13:00:00Z]}
    ]
  end
end
