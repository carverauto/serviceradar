defmodule ServiceRadarWebNG.Web.Runtime do
  @moduledoc false

  @spec web_children() :: [module()]
  def web_children do
    ServiceRadarWebNGWeb.Runtime.web_children()
  end

  @spec config_change(keyword(), [atom()]) :: :ok
  def config_change(changed, removed) do
    ServiceRadarWebNGWeb.Runtime.config_change(changed, removed)
  end
end
