defmodule ServiceRadarWebNGWeb.RemoteAccessLive.SSHTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  setup :register_and_log_in_admin_user

  setup do
    previous_enabled = Application.get_env(:serviceradar_web_ng, :remote_access_ssh_enabled)

    Application.put_env(:serviceradar_web_ng, :remote_access_ssh_enabled, true)

    on_exit(fn -> restore_env(:remote_access_ssh_enabled, previous_enabled) end)
  end

  test "requires an authenticated browser session" do
    assert {:error, {:redirect, %{to: path}}} =
             live(build_conn(), "/devices/sr%3Atest-device-1/remote-access/ssh")

    assert path == ~p"/users/log-in"
  end

  test "console props carry a colon-encoded ssh-options path for sr: uids", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/devices/sr%3Atest-device-1/remote-access/ssh")

    assert has_element?(view, "[phx-hook='RemoteAccessSSHConsole']")

    assert has_element?(
             view,
             "[data-props*='/api/remote-access/devices/sr%3Atest-device-1/ssh-options']"
           )

    assert has_element?(view, "[data-props*='test-device-1']")
  end

  test "does not render the console when SSH is disabled", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :remote_access_ssh_enabled, false)

    {:ok, view, _html} = live(conn, "/devices/sr%3Atest-device-1/remote-access/ssh")

    refute has_element?(view, "[phx-hook='RemoteAccessSSHConsole']")
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
