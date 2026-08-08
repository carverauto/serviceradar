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
end
