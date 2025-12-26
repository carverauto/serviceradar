defmodule ServiceRadarWebNG.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  # Ensure the atom exists before AshAuthentication LiveSessions attempt to use it.
  @current_user_atom :current_user

  @impl true
  def start(_type, _args) do
    _ = @current_user_atom

    children = [
      # Web telemetry
      ServiceRadarWebNGWeb.Telemetry,
      # GRPC client supervisor for datasvc connections
      {GRPC.Client.Supervisor, []},
      # DNS cluster for Kubernetes deployments
      {DNSCluster,
       query: Application.get_env(:serviceradar_web_ng, :dns_cluster_query) || :ignore},
      # Phoenix PubSub for web-specific real-time features
      {Phoenix.PubSub, name: ServiceRadarWebNG.PubSub},
      # Start to serve requests, typically the last entry
      ServiceRadarWebNGWeb.Endpoint
    ]

    # Note: ServiceRadar.Repo, Oban, and cluster infrastructure
    # are started by the serviceradar_core application

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
