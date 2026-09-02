defmodule ServiceRadarWebNGWeb.LogLive.NetflowRangeSelectionTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.Netflow.RangeSelection

  @moduletag :db_free

  test "lines derive exact inclusive bucket bounds and do not infer across missing buckets" do
    assert [
             %{
               x: first_x,
               start: "2026-08-27T10:00:00Z",
               end: "2026-08-27T10:04:59.999999Z"
             },
             %{
               x: 500.0,
               start: "2026-08-27T10:15:00Z",
               end: "2026-08-27T10:19:59.999999Z"
             },
             %{
               x: 1000.0,
               start: "2026-08-27T10:30:00Z",
               end: "2026-08-27T10:34:59.999999Z"
             }
           ] = RangeSelection.intervals(points_with_gaps(), :lines, 1000)

    assert first_x == 0.0
  end

  test "a single line point is centered in the plot" do
    assert [
             %{
               x: 500.0,
               start: "2026-08-27T10:00:00Z",
               end: "2026-08-27T10:04:59.999999Z"
             }
           ] = RangeSelection.intervals([hd(points_with_gaps())], :lines, 1000)
  end

  test "grid points use fitted band centers" do
    assert [
             %{x: 150.0},
             %{x: 450.0},
             %{x: 750.0}
           ] = RangeSelection.intervals(points_with_gaps(), :grid, 900)
  end

  test "selectable geometry is finite, strictly increasing, and inside the plot" do
    for mode <- [:lines, :grid], count <- 2..12 do
      xs =
        count
        |> points_with_count()
        |> RangeSelection.intervals(mode, 937)
        |> Enum.map(& &1.x)

      assert Enum.all?(xs, fn x -> is_number(x) and x >= 0 and x <= 937 end)
      assert Enum.all?(Enum.chunk_every(xs, 2, 1, :discard), fn [left, right] -> left < right end)
    end
  end

  test "validates canonical multi-bucket and one-bucket selections" do
    assert {:ok,
            %{
              start: "2026-08-27T10:00:00Z",
              end: "2026-08-27T10:19:59.999999Z"
            }} =
             RangeSelection.validate(
               %{
                 "start" => "2026-08-27T10:00:00Z",
                 "end" => "2026-08-27T10:19:59.999999Z"
               },
               points_with_gaps()
             )

    assert {:ok,
            %{
              start: "2026-08-27T10:15:00Z",
              end: "2026-08-27T10:19:59.999999Z"
            }} =
             RangeSelection.validate(
               %{
                 "start" => "2026-08-27T10:15:00Z",
                 "end" => "2026-08-27T10:19:59.999999Z"
               },
               points_with_gaps()
             )
  end

  test "rejects malformed, equal, reversed, stale, out-of-window, mismatched, and expanded payloads" do
    invalid = [
      %{"start" => "bad", "end" => "2026-08-27T10:04:59.999999Z"},
      %{"start" => "2026-08-27T10:00:00Z", "end" => "bad"},
      %{"start" => "2026-08-27T10:00:00Z", "end" => "2026-08-27T10:00:00Z"},
      %{"start" => "2026-08-27T10:15:00Z", "end" => "2026-08-27T10:04:59.999999Z"},
      %{"start" => "2026-08-27T09:55:00Z", "end" => "2026-08-27T10:04:59.999999Z"},
      %{"start" => "2026-08-27T10:00:00Z", "end" => "2026-08-27T10:39:59.999999Z"},
      %{"start" => "2026-08-27T10:00:00Z", "end" => "2026-08-27T10:14:59.999999Z"},
      %{"start" => "2026-08-27T10:01:00Z", "end" => "2026-08-27T10:19:59.999999Z"},
      %{"start" => "2026-08-27T10:00:00Z"},
      %{"end" => "2026-08-27T10:04:59.999999Z"},
      %{
        "start" => "2026-08-27T10:00:00Z",
        "end" => "2026-08-27T10:04:59.999999Z",
        "query" => "in:flows"
      }
    ]

    for params <- invalid do
      assert :error = RangeSelection.validate(params, points_with_gaps())
    end
  end

  defp points_with_gaps do
    [
      point(~U[2026-08-27 10:00:00Z], ~U[2026-08-27 10:05:00Z]),
      point(~U[2026-08-27 10:15:00Z], ~U[2026-08-27 10:20:00Z]),
      point(~U[2026-08-27 10:30:00Z], ~U[2026-08-27 10:35:00Z])
    ]
  end

  defp points_with_count(count) do
    for index <- 0..(count - 1) do
      start = DateTime.add(~U[2026-08-27 10:00:00Z], index * 300, :second)
      point(start, DateTime.add(start, 300, :second))
    end
  end

  defp point(start_time, end_time) do
    %{bucket_start: start_time, bucket_end: end_time, bytes: 100}
  end
end
