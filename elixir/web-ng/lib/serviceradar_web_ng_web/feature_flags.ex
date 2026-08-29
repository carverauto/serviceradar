defmodule ServiceRadarWebNGWeb.FeatureFlags do
  @moduledoc """
  Runtime feature flags for web-ng UI capabilities.
  """

  @spec god_view_enabled?() :: boolean()
  def god_view_enabled? do
    Application.get_env(:serviceradar_web_ng, :god_view_enabled, false) == true
  end

  @spec mcp_enabled?() :: boolean()
  def mcp_enabled? do
    Application.get_env(:serviceradar_web_ng, :mcp_enabled, false) == true
  end

  @spec mcp_client_credentials_enabled?() :: boolean()
  def mcp_client_credentials_enabled? do
    Application.get_env(:serviceradar_web_ng, :mcp_client_credentials_enabled, true) != false
  end

  @spec remote_access_ssh_enabled?() :: boolean()
  def remote_access_ssh_enabled? do
    Application.get_env(:serviceradar_web_ng, :remote_access_ssh_enabled, false) == true
  end

  @spec remote_access_desktop_rdp_enabled?() :: boolean()
  def remote_access_desktop_rdp_enabled? do
    Application.get_env(:serviceradar_web_ng, :remote_access_desktop_rdp_enabled, false) == true
  end

  @spec remote_access_app_enabled?() :: boolean()
  def remote_access_app_enabled? do
    Application.get_env(:serviceradar_web_ng, :remote_access_app_enabled, false) == true
  end

  @spec remote_access_tcp_enabled?() :: boolean()
  def remote_access_tcp_enabled? do
    Application.get_env(:serviceradar_web_ng, :remote_access_tcp_enabled, false) == true
  end
end
