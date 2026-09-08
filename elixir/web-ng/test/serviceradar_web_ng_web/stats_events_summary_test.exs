defmodule ServiceRadarWebNGWeb.StatsEventsSummaryTest do
  use ServiceRadarWebNG.DataCase, async: false

  alias ServiceRadarWebNGWeb.Stats

  test "includes current-hour events before the hourly aggregate refreshes" do
    before = Stats.events_summary(time: "last_1h")
    now = DateTime.truncate(DateTime.utc_now(), :second)

    insert_event!(now, 5)
    insert_event!(now, 4)
    insert_event!(now, 2)

    after_summary = Stats.events_summary(time: "last_1h")

    assert after_summary.total == before.total + 3
    assert after_summary.critical == before.critical + 1
    assert after_summary.high == before.high + 1
    assert after_summary.low == before.low + 1
  end

  test "falls back to raw events when the hourly rollup has no closed hours" do
    past = DateTime.utc_now() |> DateTime.add(-3, :hour) |> DateTime.truncate(:second)
    before = Stats.events_summary(time: "last_24h")
    before_trend = Stats.events_hourly_trend(DateTime.add(DateTime.utc_now(), -24, :hour))

    insert_event!(past, 4)

    after_summary = Stats.events_summary(time: "last_24h")
    after_trend = Stats.events_hourly_trend(DateTime.add(DateTime.utc_now(), -24, :hour))

    if closed_hour_rollup_present?() do
      assert after_summary.total >= before.total
      assert is_list(after_trend)
    else
      assert after_summary.total == before.total + 1
      assert after_summary.high == before.high + 1
      assert length(after_trend) >= length(before_trend)

      past_hour = past |> DateTime.truncate(:second) |> Map.put(:minute, 0) |> Map.put(:second, 0)

      assert Enum.any?(after_trend, fn point ->
               same_hour?(point.bucket, past_hour) and point.high >= 1
             end)
    end
  end

  defp insert_event!(time, severity_id) do
    {1, _} =
      Repo.insert_all("ocsf_events", [
        %{
          id: Ecto.UUID.dump!(Ecto.UUID.generate()),
          time: time,
          class_uid: 2_004,
          category_uid: 2,
          type_uid: 2_004_001,
          activity_id: 1,
          severity_id: severity_id
        }
      ])
  end

  defp closed_hour_rollup_present? do
    sql = """
    SELECT EXISTS (
      SELECT 1
      FROM ocsf_events_hourly_stats
      WHERE bucket < date_trunc('hour', now())
      LIMIT 1
    )
    """

    case Repo.query(sql, []) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  defp same_hour?(%DateTime{} = left, %DateTime{} = right) do
    DateTime.truncate(left, :second).year == right.year and
      left.month == right.month and
      left.day == right.day and
      left.hour == right.hour
  end

  defp same_hour?(%NaiveDateTime{} = left, %DateTime{} = right) do
    left.year == right.year and left.month == right.month and left.day == right.day and
      left.hour == right.hour
  end

  defp same_hour?(_, _), do: false
end
