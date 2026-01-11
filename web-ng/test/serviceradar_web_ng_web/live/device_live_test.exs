defmodule ServiceRadarWebNGWeb.DeviceLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  alias ServiceRadarWebNG.Repo
  import Phoenix.LiveViewTest
  import ServiceRadarWebNG.DataCase, only: [test_tenant_id: 0]

  setup :register_and_log_in_user

  test "renders devices from ocsf_devices", %{conn: conn} do
    uid = "test-device-live-#{System.unique_integer([:positive])}"
    {:ok, tenant_uuid} = Ecto.UUID.dump(test_tenant_id())

    Repo.insert_all("ocsf_devices", [
      %{
        uid: uid,
        type_id: 0,
        hostname: "test-host",
        is_available: true,
        first_seen_time: ~U[2100-01-01 00:00:00Z],
        last_seen_time: ~U[2100-01-01 00:00:00Z],
        tenant_id: tenant_uuid
      }
    ])

    {:ok, _lv, html} = live(conn, ~p"/devices?limit=10")
    assert html =~ uid
    assert html =~ "test-host"
    assert html =~ "in:devices"
  end
end
