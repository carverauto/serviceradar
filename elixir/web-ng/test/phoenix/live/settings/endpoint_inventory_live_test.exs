defmodule ServiceRadarWebNGWeb.Settings.EndpointInventoryLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Actors.SystemActor
  alias ServiceRadar.Identity.RBAC
  alias ServiceRadar.Inventory.EndpointInventorySettings
  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  setup :register_and_log_in_admin_user

  test "renders endpoint inventory settings page", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/settings/agents/endpoint-inventory")

    assert html =~ "Endpoint Inventory"
    assert html =~ "Historical scan retention (days)"
  end

  test "updates endpoint inventory settings", %{conn: conn} do
    assert {:ok, %EndpointInventorySettings{}} =
             EndpointInventorySettings.create(%{retention_days: 30},
               actor: SystemActor.system(:endpoint_inventory_settings_test)
             )

    {:ok, lv, _html} = live(conn, ~p"/settings/agents/endpoint-inventory")

    lv
    |> form("#endpoint-inventory-settings-form", %{
      "settings" => %{
        "retention_days" => "45"
      }
    })
    |> render_submit()

    assert {:ok, %EndpointInventorySettings{retention_days: 45}} =
             EndpointInventorySettings.get_settings(actor: SystemActor.system(:endpoint_inventory_settings_test))
  end

  test "viewer is blocked from endpoint inventory settings", %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{role: :viewer})
    conn = log_in_user(conn, user)

    assert {:error, {:redirect, %{to: to}}} =
             live(conn, ~p"/settings/agents/endpoint-inventory")

    assert to == ~p"/settings/profile"
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user, permissions: RBAC.permissions_for_user(user))

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end
end
