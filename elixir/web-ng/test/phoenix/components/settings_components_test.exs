defmodule ServiceRadarWebNGWeb.Components.SettingsComponentsTest do
  @moduledoc """
  Subnav visibility rules for `SettingsComponents`. Named for its directory, like
  every other module under `test/phoenix/components/`: this file previously used
  the bare `ServiceRadarWebNGWeb.SettingsComponentsTest`, colliding with
  `test/phoenix/settings/settings_components_test.exs`. Both were loaded into one
  VM, the second definition won, and all five tests below silently never ran.
  """

  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias ServiceRadarWebNG.Accounts.Scope
  alias ServiceRadarWebNGWeb.SettingsComponents

  @moduletag :db_free

  test "credential manager sees credentials and rules in the network settings subnav" do
    scope = %Scope{permissions: MapSet.new(["settings.credentials.manage"])}

    top_tabs = SettingsComponents.settings_tabs("/settings/networks/credentials", scope)

    html =
      render_component(&SettingsComponents.network_nav/1,
        current_path: "/settings/networks/credentials",
        current_scope: scope
      )

    assert Enum.any?(top_tabs, &(&1.label == "Discovery" and &1.active))
    assert html =~ "Credentials and Rules"
    refute html =~ ">Credential Rules<"
    refute html =~ "Sweep Profiles"
  end

  test "alert manager sees anomaly detection in the events settings subnav" do
    scope = %Scope{permissions: MapSet.new(["observability.alerts.manage"])}

    top_tabs = SettingsComponents.settings_tabs("/settings/anomaly-detection", scope)

    html =
      render_component(&SettingsComponents.events_nav/1,
        current_path: "/settings/anomaly-detection",
        current_scope: scope
      )

    assert Enum.any?(top_tabs, &(&1.label == "Events" and &1.active))
    assert html =~ "Anomaly Detection"
    refute html =~ "Rules"
  end

  test "remote access tabs are hidden when SSH remote access is disabled" do
    previous = Application.get_env(:serviceradar_web_ng, :remote_access_ssh_enabled)
    previous_rdp = Application.get_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled)
    Application.put_env(:serviceradar_web_ng, :remote_access_ssh_enabled, false)
    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, false)

    on_exit(fn ->
      restore_env(:remote_access_ssh_enabled, previous)
      restore_env(:remote_access_desktop_rdp_enabled, previous_rdp)
    end)

    scope =
      %Scope{
        permissions:
          MapSet.new([
            "settings.remote_access_host_keys.manage",
            "devices.remote_access.ssh.open"
          ])
      }

    html =
      render_component(&SettingsComponents.network_nav/1,
        current_path: "/settings/networks/host-keys",
        current_scope: scope
      )

    refute html =~ "Host Keys"
    refute html =~ "Recordings"
  end

  test "recordings tab is visible for RDP-only remote access deployments" do
    previous_ssh = Application.get_env(:serviceradar_web_ng, :remote_access_ssh_enabled)
    previous_rdp = Application.get_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled)
    Application.put_env(:serviceradar_web_ng, :remote_access_ssh_enabled, false)
    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, true)

    on_exit(fn ->
      restore_env(:remote_access_ssh_enabled, previous_ssh)
      restore_env(:remote_access_desktop_rdp_enabled, previous_rdp)
    end)

    scope = %Scope{permissions: MapSet.new(["devices.remote_access.rdp.open"])}

    html =
      render_component(&SettingsComponents.network_nav/1,
        current_path: "/settings/networks/recordings",
        current_scope: scope
      )

    assert html =~ "Recordings"
    refute html =~ "Host Keys"
  end

  test "remote access tabs are visible when SSH remote access is enabled" do
    previous = Application.get_env(:serviceradar_web_ng, :remote_access_ssh_enabled)
    Application.put_env(:serviceradar_web_ng, :remote_access_ssh_enabled, true)

    on_exit(fn ->
      restore_env(:remote_access_ssh_enabled, previous)
    end)

    scope =
      %Scope{
        permissions:
          MapSet.new([
            "settings.remote_access_host_keys.manage",
            "devices.remote_access.ssh.open"
          ])
      }

    html =
      render_component(&SettingsComponents.network_nav/1,
        current_path: "/settings/networks/host-keys",
        current_scope: scope
      )

    assert html =~ "Host Keys"
    assert html =~ "Recordings"
  end

  defp restore_env(key, nil), do: Application.delete_env(:serviceradar_web_ng, key)
  defp restore_env(key, value), do: Application.put_env(:serviceradar_web_ng, key, value)
end
