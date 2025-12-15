defmodule ServiceRadarWebNGWeb.Dashboard.Registry do
  @moduledoc false

  alias ServiceRadarWebNGWeb.Dashboard.Plugins

  def plugins do
    [
      Plugins.Timeseries,
      Plugins.GraphResult,
      Plugins.Categories,
      Plugins.Table
    ]
  end
end
