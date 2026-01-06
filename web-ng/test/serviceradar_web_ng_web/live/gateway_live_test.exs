defmodule ServiceRadarWebNGWeb.GatewayLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: true

  alias ServiceRadarWebNG.Repo
  import Phoenix.LiveViewTest
  import ServiceRadarWebNG.DataCase, only: [test_tenant_id: 0]

  setup :register_and_log_in_user

  test "renders gateways from gateways table", %{conn: conn} do
    gateway_id = "test-gateway-live-#{System.unique_integer([:positive])}"
    {:ok, tenant_uuid} = Ecto.UUID.dump(test_tenant_id())

    Repo.insert_all("gateways", [
      %{
        gateway_id: gateway_id,
        last_seen: ~U[2100-01-01 00:00:00Z],
        status: "healthy",
        tenant_id: tenant_uuid
      }
    ])

    {:ok, _lv, html} = live(conn, ~p"/gateways?limit=10")
    assert html =~ gateway_id
    assert html =~ "healthy"
    assert html =~ "in:gateways"
  end
end
