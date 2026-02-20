defmodule ServiceRadarWebNGWeb.FeatureFlagsTest do
  use ExUnit.Case, async: true

  alias ServiceRadarWebNGWeb.FeatureFlags

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
end
