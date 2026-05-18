defmodule ServiceRadarWebNGWeb.RemoteAccessApplicationLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ServiceRadarWebNG.AshTestHelpers, only: [admin_user_fixture: 0]

  setup %{conn: conn} do
    previous_app_enabled = Application.get_env(:serviceradar_web_ng, :remote_access_app_enabled)
    Application.put_env(:serviceradar_web_ng, :remote_access_app_enabled, true)

    on_exit(fn -> restore_env(:remote_access_app_enabled, previous_app_enabled) end)

    user = admin_user_fixture()

    %{conn: log_in_user(conn, user)}
  end

  test "renders authenticated application access launcher", %{conn: conn} do
    target_id = Ecto.UUID.generate()

    {:ok, _view, html} = live(conn, ~p"/remote-access/applications/#{target_id}")

    assert html =~ "Application remote access"
    assert html =~ target_id
    assert html =~ "RemoteAccessApplication"
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
