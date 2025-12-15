defmodule ServiceRadarWebNGWeb.DeviceLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  alias ServiceRadarWebNG.Repo
  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  test "renders devices from unified_devices", %{conn: conn} do
    device_id = "test-device-live-#{System.unique_integer([:positive])}"

    Repo.insert_all("unified_devices", [
      %{
        device_id: device_id,
        hostname: "test-host",
        last_seen: ~U[2100-01-01 00:00:00Z]
      }
    ])

    {:ok, _lv, html} = live(conn, ~p"/devices?limit=10")
    assert html =~ device_id
    assert html =~ "test-host"
  end
end
