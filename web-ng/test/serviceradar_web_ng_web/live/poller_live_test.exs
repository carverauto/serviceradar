defmodule ServiceRadarWebNGWeb.PollerLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  alias ServiceRadarWebNG.Repo
  import Phoenix.LiveViewTest
  import ServiceRadarWebNG.DataCase, only: [test_tenant_id: 0]

  setup :register_and_log_in_user

  test "renders pollers from pollers table", %{conn: conn} do
    poller_id = "test-poller-live-#{System.unique_integer([:positive])}"
    {:ok, tenant_uuid} = Ecto.UUID.dump(test_tenant_id())

    Repo.insert_all("pollers", [
      %{
        poller_id: poller_id,
        last_seen: ~U[2100-01-01 00:00:00Z],
        status: "active",
        tenant_id: tenant_uuid
      }
    ])

    {:ok, _lv, html} = live(conn, ~p"/pollers?limit=10")
    assert html =~ poller_id
    assert html =~ "active"
    assert html =~ "in:pollers"
  end
end
