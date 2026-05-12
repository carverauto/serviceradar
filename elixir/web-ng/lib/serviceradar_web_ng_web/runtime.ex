defmodule ServiceRadarWebNGWeb.Runtime do
  @moduledoc false

  @spec web_children() :: [module()]
  def web_children do
    [
      ServiceRadarWebNGWeb.Telemetry,
      ServiceRadarWebNGWeb.Auth.ConfigCache,
      # ServiceRadarWebNGWeb.Auth.RateLimiter — replaced by the supervised
      # ServiceRadar.Security.RateLimiter in serviceradar_core. The web
      # shim no longer needs a supervised process.
      ServiceRadarWebNG.Auth.TokenRevocation,
      ServiceRadarWebNGWeb.Endpoint
    ]
  end

  @spec config_change(keyword(), [atom()]) :: :ok
  def config_change(changed, removed) do
    ServiceRadarWebNGWeb.Endpoint.config_change(changed, removed)
  end
end
