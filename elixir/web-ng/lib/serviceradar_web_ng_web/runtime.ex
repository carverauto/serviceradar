defmodule ServiceRadarWebNGWeb.Runtime do
  @moduledoc false

  @spec web_children() :: [module()]
  def web_children do
    [
      ServiceRadarWebNGWeb.Telemetry,
      ServiceRadarWebNGWeb.Auth.ConfigCache,
      ServiceRadarWebNGWeb.Auth.RateLimiter,
      ServiceRadarWebNGWeb.Auth.TokenRevocation,
      ServiceRadarWebNGWeb.Endpoint
    ]
  end

  @spec config_change(keyword(), [atom()]) :: :ok
  def config_change(changed, removed) do
    ServiceRadarWebNGWeb.Endpoint.config_change(changed, removed)
  end
end
