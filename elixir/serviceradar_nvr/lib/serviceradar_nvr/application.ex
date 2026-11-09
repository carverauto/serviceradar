defmodule ServiceRadarNVR.Application do
  @moduledoc false
  use Application

  alias ServiceRadarNVR.Config

  @impl true
  def start(_type, _args) do
    with {:ok, config} <- Config.load(System.get_env()) do
      children = [
        {Registry, keys: :unique, name: ServiceRadarNVR.Registry},
        {DynamicSupervisor,
         name: ServiceRadarNVR.Sessions,
         strategy: :one_for_one,
         max_children: config.max_sessions,
         extra_arguments: [config]},
        {Bandit, plug: {ServiceRadarNVR.Health, config}, port: config.health_port}
      ]

      # Losing the local identity registry also retires its admitted workers.
      Supervisor.start_link(children, strategy: :rest_for_one, name: ServiceRadarNVR.Supervisor)
    end
  end
end
