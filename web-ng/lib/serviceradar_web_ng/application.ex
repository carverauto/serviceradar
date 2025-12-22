defmodule ServiceRadarWebNG.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ServiceRadarWebNGWeb.Telemetry,
      ServiceRadarWebNG.Repo,
      {Oban, Application.fetch_env!(:serviceradar_web_ng, Oban)},
      {DNSCluster,
       query: Application.get_env(:serviceradar_web_ng, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ServiceRadarWebNG.PubSub},
      # Start a worker by calling: ServiceRadarWebNG.Worker.start_link(arg)
      # {ServiceRadarWebNG.Worker, arg},
      # Start to serve requests, typically the last entry
      ServiceRadarWebNGWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ServiceRadarWebNG.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ServiceRadarWebNGWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
