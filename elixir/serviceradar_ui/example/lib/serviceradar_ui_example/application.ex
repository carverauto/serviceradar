defmodule ServiceRadarUIExample.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: ServiceRadarUIExample.PubSub},
      ServiceRadarUIExample.Endpoint
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: ServiceRadarUIExample.Supervisor
    )
  end

  @impl true
  def config_change(changed, _new, removed) do
    ServiceRadarUIExample.Endpoint.config_change(changed, removed)
    :ok
  end
end
