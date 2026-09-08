defmodule ServiceRadarWebNGWeb.DeviceLive.IndexData.Stats.NewDeviceWindowsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.DeviceLive.IndexData.Stats

  @moduletag :unit
  @moduletag :db_free

  test "new device windows match SRQL today / last_7d / last_30d" do
    now = ~U[2026-08-13 15:04:05Z]

    assert [
             %{
               key: :new_today,
               token: "today",
               label: "Today",
               since: ~U[2026-08-13 00:00:00Z],
               until: ~U[2026-08-13 15:04:05Z]
             },
             %{
               key: :new_last_7d,
               token: "last_7d",
               label: "7d",
               since: ~U[2026-08-06 15:04:05Z],
               until: ~U[2026-08-13 15:04:05Z]
             },
             %{
               key: :new_last_30d,
               token: "last_30d",
               label: "30d",
               since: ~U[2026-07-14 15:04:05Z],
               until: ~U[2026-08-13 15:04:05Z]
             }
           ] = Stats.new_device_windows(now)
  end
end
