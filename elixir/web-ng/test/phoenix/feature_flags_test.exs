defmodule ServiceRadarWebNGWeb.FeatureFlagsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.FeatureFlags

  @moduletag :db_free

  test "mcp_enabled?/0 is false unless explicitly enabled" do
    original = Application.get_env(:serviceradar_web_ng, :mcp_enabled)
    on_exit(fn -> Application.put_env(:serviceradar_web_ng, :mcp_enabled, original) end)

    Application.put_env(:serviceradar_web_ng, :mcp_enabled, false)
    refute FeatureFlags.mcp_enabled?()

    Application.put_env(:serviceradar_web_ng, :mcp_enabled, true)
    assert FeatureFlags.mcp_enabled?()
  end

  test "mcp_client_credentials_enabled?/0 defaults to true" do
    original = Application.get_env(:serviceradar_web_ng, :mcp_client_credentials_enabled)
    on_exit(fn -> Application.put_env(:serviceradar_web_ng, :mcp_client_credentials_enabled, original) end)

    Application.put_env(:serviceradar_web_ng, :mcp_client_credentials_enabled, true)
    assert FeatureFlags.mcp_client_credentials_enabled?()

    Application.put_env(:serviceradar_web_ng, :mcp_client_credentials_enabled, false)
    refute FeatureFlags.mcp_client_credentials_enabled?()
  end

  test "god_view_enabled?/0 is false by default" do
    original = Application.get_env(:serviceradar_web_ng, :god_view_enabled)
    on_exit(fn -> Application.put_env(:serviceradar_web_ng, :god_view_enabled, original) end)

    Application.put_env(:serviceradar_web_ng, :god_view_enabled, false)
    refute FeatureFlags.god_view_enabled?()
  end

  test "god_view_enabled?/0 returns true when enabled" do
    original = Application.get_env(:serviceradar_web_ng, :god_view_enabled)
    on_exit(fn -> Application.put_env(:serviceradar_web_ng, :god_view_enabled, original) end)

    Application.put_env(:serviceradar_web_ng, :god_view_enabled, true)
    assert FeatureFlags.god_view_enabled?()
  end

  test "remote_access_ssh_enabled?/0 is false by default" do
    original = Application.get_env(:serviceradar_web_ng, :remote_access_ssh_enabled)
    on_exit(fn -> Application.put_env(:serviceradar_web_ng, :remote_access_ssh_enabled, original) end)

    Application.put_env(:serviceradar_web_ng, :remote_access_ssh_enabled, false)
    refute FeatureFlags.remote_access_ssh_enabled?()
  end

  test "remote_access_ssh_enabled?/0 returns true when enabled" do
    original = Application.get_env(:serviceradar_web_ng, :remote_access_ssh_enabled)
    on_exit(fn -> Application.put_env(:serviceradar_web_ng, :remote_access_ssh_enabled, original) end)

    Application.put_env(:serviceradar_web_ng, :remote_access_ssh_enabled, true)
    assert FeatureFlags.remote_access_ssh_enabled?()
  end

  test "remote_access_desktop_rdp_enabled?/0 is false by default" do
    original = Application.get_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled)

    on_exit(fn ->
      Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, original)
    end)

    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, false)
    refute FeatureFlags.remote_access_desktop_rdp_enabled?()
  end

  test "remote_access_desktop_rdp_enabled?/0 returns true when enabled" do
    original = Application.get_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled)

    on_exit(fn ->
      Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, original)
    end)

    Application.put_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, true)
    assert FeatureFlags.remote_access_desktop_rdp_enabled?()
  end

  test "remote_access_app_enabled?/0 is false by default" do
    original = Application.get_env(:serviceradar_web_ng, :remote_access_app_enabled)
    on_exit(fn -> Application.put_env(:serviceradar_web_ng, :remote_access_app_enabled, original) end)

    Application.put_env(:serviceradar_web_ng, :remote_access_app_enabled, false)
    refute FeatureFlags.remote_access_app_enabled?()
  end

  test "remote_access_app_enabled?/0 returns true when enabled" do
    original = Application.get_env(:serviceradar_web_ng, :remote_access_app_enabled)
    on_exit(fn -> Application.put_env(:serviceradar_web_ng, :remote_access_app_enabled, original) end)

    Application.put_env(:serviceradar_web_ng, :remote_access_app_enabled, true)
    assert FeatureFlags.remote_access_app_enabled?()
  end

  test "remote_access_tcp_enabled?/0 is false by default" do
    original = Application.get_env(:serviceradar_web_ng, :remote_access_tcp_enabled)
    on_exit(fn -> Application.put_env(:serviceradar_web_ng, :remote_access_tcp_enabled, original) end)

    Application.put_env(:serviceradar_web_ng, :remote_access_tcp_enabled, false)
    refute FeatureFlags.remote_access_tcp_enabled?()
  end

  test "remote_access_tcp_enabled?/0 returns true when enabled" do
    original = Application.get_env(:serviceradar_web_ng, :remote_access_tcp_enabled)
    on_exit(fn -> Application.put_env(:serviceradar_web_ng, :remote_access_tcp_enabled, original) end)

    Application.put_env(:serviceradar_web_ng, :remote_access_tcp_enabled, true)
    assert FeatureFlags.remote_access_tcp_enabled?()
  end
end
