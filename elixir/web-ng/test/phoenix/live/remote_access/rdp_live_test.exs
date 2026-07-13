defmodule ServiceRadarWebNGWeb.RemoteAccessLive.RDPTest do
  use ServiceRadarWebNGWeb.ConnCase, async: false
  use ServiceRadarWebNG.AshTestHelpers

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNG.AccountsFixtures

  setup :register_and_log_in_admin_user

  setup do
    previous_enabled =
      Application.get_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled)

    previous_targets =
      Application.get_env(:serviceradar_web_ng, :remote_access_desktop_targets)

    previous_provider =
      Application.get_env(:serviceradar_web_ng, :remote_access_desktop_target_provider)

    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, true)
    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_targets, [])
    Application.delete_env(:serviceradar_web_ng, :remote_access_desktop_target_provider)

    on_exit(fn ->
      restore_env(:remote_access_desktop_rdp_enabled, previous_enabled)
      restore_env(:remote_access_desktop_targets, previous_targets)
      restore_env(:remote_access_desktop_target_provider, previous_provider)
    end)
  end

  test "requires an authenticated browser session" do
    assert {:error, {:redirect, %{to: path}}} =
             live(build_conn(), ~p"/devices/windows-1/remote-access/rdp")

    assert path == ~p"/users/log-in"
  end

  test "loads only the enabled authorized target with an exact device uid", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_targets, [
      desktop_target("disabled-exact", "windows-1", false),
      desktop_target("enabled-other", "windows-10", true),
      desktop_target("enabled-exact", "windows-1", true)
    ])

    {:ok, view, _html} = live(conn, ~p"/devices/windows-1/remote-access/rdp")

    assert has_element?(view, "#remote-access-rdp-windows-1[phx-hook='RemoteAccessDesktopSession']")
    assert has_element?(view, "#remote-access-rdp-windows-1[data-props*='enabled-exact']")
    refute has_element?(view, "[data-props*='rdp-password-must-not-render']")
    refute has_element?(view, "[data-props*='target_host']")
    refute has_element?(view, "[data-props*='agent_id']")
  end

  test "does not render the launcher when RDP is disabled", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, false)
    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_targets, [desktop_target("target-1", "windows-1")])

    {:ok, view, _html} = live(conn, ~p"/devices/windows-1/remote-access/rdp")

    assert has_element?(view, "#rdp-launch-availability.alert-warning")
    refute has_element?(view, "[phx-hook='RemoteAccessDesktopSession']")
  end

  test "does not load target data for a user without RDP open permission", %{conn: conn} do
    viewer = AccountsFixtures.user_fixture(%{role: :viewer})
    conn = log_in_user(conn, viewer)
    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_targets, [desktop_target("target-1", "windows-1")])

    {:ok, view, _html} = live(conn, ~p"/devices/windows-1/remote-access/rdp")

    assert has_element?(view, "#rdp-launch-availability.alert-error")
    refute has_element?(view, "[phx-hook='RemoteAccessDesktopSession']")
  end

  test "does not fall back to a similarly named or freeform target", %{conn: conn} do
    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_targets, [
      desktop_target("similar-device", "windows-10"),
      desktop_target("freeform-device", "windows-1", true, "freeform_target")
    ])

    {:ok, view, _html} = live(conn, ~p"/devices/windows-1/remote-access/rdp")

    assert has_element?(view, "#rdp-launch-availability")
    refute has_element?(view, "[phx-hook='RemoteAccessDesktopSession']")
  end

  defp register_and_log_in_admin_user(%{conn: conn}) do
    user = AccountsFixtures.user_fixture(%{role: :admin})
    scope = Scope.for_user(user)

    %{conn: log_in_user(conn, user), user: user, scope: scope}
  end

  defp desktop_target(id, device_uid, enabled \\ true, target_kind \\ "inventory_device") do
    %{
      id: id,
      enabled: enabled,
      label: id,
      device_uid: device_uid,
      target_kind: target_kind,
      target_host: "#{id}.example.test",
      target_port: 3389,
      agent_id: "agent-#{id}",
      gateway_id: "gateway-platform",
      credential_custody_mode: "user_present",
      metadata: %{"password" => "rdp-password-must-not-render"}
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
