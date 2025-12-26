defmodule ServiceRadarCoreElx.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting ServiceRadar Core-ELX node: #{node()}")

    children = []
    opts = [strategy: :one_for_one, name: ServiceRadarCoreElx.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
