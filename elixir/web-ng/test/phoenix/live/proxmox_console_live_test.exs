defmodule ServiceRadarWebNGWeb.ProxmoxConsoleLiveTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadar.Identity.RBAC.Cache
  alias ServiceRadarWebNG.AshTestHelpers
  alias ServiceRadarWebNG.TestSupport.ProxmoxConsoleSessionManagerStub

  setup %{conn: conn} do
    previous_manager = Application.get_env(:serviceradar_web_ng, :proxmox_console_session_manager)
    previous_test_pid = Application.get_env(:serviceradar_web_ng, :proxmox_console_session_manager_test_pid)
    previous_open_result = Application.get_env(:serviceradar_web_ng, :proxmox_console_session_manager_open_result)

    Application.put_env(
      :serviceradar_web_ng,
      :proxmox_console_session_manager,
      ProxmoxConsoleSessionManagerStub
    )

    Application.put_env(
      :serviceradar_web_ng,
      :proxmox_console_session_manager_test_pid,
      self()
    )

    on_exit(fn ->
      restore_env(:proxmox_console_session_manager, previous_manager)
      restore_env(:proxmox_console_session_manager_test_pid, previous_test_pid)
      restore_env(:proxmox_console_session_manager_open_result, previous_open_result)
    end)

    user = AshTestHelpers.admin_user_fixture()

    %{conn: log_in_user(conn, user), user: user}
  end

  test "ignores browser-supplied Proxmox target and console mode", %{conn: conn} do
    Application.put_env(
      :serviceradar_web_ng,
      :proxmox_console_session_manager_open_result,
      {:error, :no_console_credential_rule}
    )

    {:ok, _view, html} =
      live(
        conn,
        ~p"/devices/pve-guest-1/proxmox-console?target_kind=lxc_guest&console_mode=proxmox_termproxy"
      )

    assert html =~ "No scoped console credential rule matched this device."
    assert_receive {:open_proxmox_console_session, "pve-guest-1", request, opts}
    assert request.cols == 120
    assert request.rows == 34
    refute Map.has_key?(request, :target_kind)
    refute Map.has_key?(request, :console_mode)
    assert opts[:scope]
  end

  test "successful open renders the client-only console terminal", %{conn: conn} do
    # Regression test for https://github.com/carverauto/serviceradar/issues/4373:
    # the connected mount crashed here because `remote_console_terminal`
    # rendered a server-side `react_component/1` (`static: false`) while
    # `Phoenix.ReactServer` is not supervised. The terminal must render as a
    # client-only hook so the Proxmox console opens.
    {:ok, _view, html} = live(conn, ~p"/devices/pve-guest-1/proxmox-console")

    assert_receive {:open_proxmox_console_session, "pve-guest-1", _request, _opts}
    assert html =~ ~s(phx-hook="RemoteConsoleTerminal")
    assert html =~ "data-props"
    # The client hook authenticates the websocket stream with this ticket.
    assert html =~ "srpve_test_ticket_value"
  end

  test "does not request a console session for users without console permission", %{conn: conn} do
    viewer = AshTestHelpers.viewer_user_fixture()

    {:ok, _view, html} =
      conn
      |> log_in_user(viewer)
      |> live(~p"/devices/pve-1/proxmox-console?target_kind=pve_host&console_mode=ssh")

    assert html =~ "You do not have permission to open remote consoles."
    refute_receive {:open_proxmox_console_session, _device_uid, _request, _opts}
  end

  test "does not request a session with console-open but without credential-use permission", %{
    conn: conn,
    user: user
  } do
    permissions = MapSet.new(["devices.console.open"])

    # The disconnected render runs in the test process, while the connected
    # LiveView mounts in its own process. Populate both RBAC cache tiers so the
    # permission contraction is observed consistently across that boundary.
    Process.put({:rbac_permissions, user.id}, permissions)
    Cache.put(user.id, permissions)
    on_exit(fn -> Cache.invalidate(user.id) end)

    {:ok, _view, html} =
      live(conn, ~p"/devices/pve-1/proxmox-console?target_kind=pve_host&console_mode=ssh")

    assert html =~ "You do not have permission to open remote consoles."
    refute_receive {:open_proxmox_console_session, _device_uid, _request, _opts}
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
