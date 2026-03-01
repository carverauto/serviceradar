defmodule ServiceRadarWebNGWeb.FeatureFlags do
  @moduledoc """
  Runtime feature flags for web-ng UI capabilities.
  """

  @spec god_view_enabled?() :: boolean()
  def god_view_enabled? do
    Application.get_env(:serviceradar_web_ng, :god_view_enabled, false) == true
  end
end
