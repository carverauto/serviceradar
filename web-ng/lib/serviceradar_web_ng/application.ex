defmodule ServiceRadarWebNG.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        ServiceRadarWebNGWeb.Telemetry,
        ServiceRadarWebNG.Repo,
        # GRPC client supervisor for datasvc connections
        {GRPC.Client.Supervisor, []},
        {Oban, Application.fetch_env!(:serviceradar_web_ng, Oban)},
        {DNSCluster,
         query: Application.get_env(:serviceradar_web_ng, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: ServiceRadarWebNG.PubSub}
      ] ++
        cluster_children() ++
        [
          # Start to serve requests, typically the last entry
          ServiceRadarWebNGWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ServiceRadarWebNG.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Cluster infrastructure children (conditional based on config)
  defp cluster_children do
    if cluster_enabled?() do
      [
        # Cluster supervisor manages libcluster
        ServiceRadar.ClusterSupervisor,
        # Horde distributed registries
        ServiceRadar.PollerRegistry,
        ServiceRadar.AgentRegistry,
        # Horde distributed supervisor
        ServiceRadar.PollerSupervisor,
        # Cluster health monitoring
        ServiceRadar.ClusterHealth
      ] ++ poller_registration_children()
    else
      []
    end
  end

  # Only start registration worker on poller nodes
  defp poller_registration_children do
    if poller_node?() do
      partition_id = System.get_env("POLLER_PARTITION_ID", "default")
      domain = System.get_env("POLLER_DOMAIN", "default")

      capabilities =
        System.get_env("POLLER_CAPABILITIES", "")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.to_atom/1)

      [
        {ServiceRadar.Poller.RegistrationWorker,
         partition_id: partition_id,
         domain: domain,
         capabilities: capabilities}
      ]
    else
      []
    end
  end

  defp cluster_enabled? do
    Application.get_env(:libcluster, :topologies, []) != []
  end

  defp poller_node? do
    System.get_env("POLLER_NODE", "false") in ~w(true 1 yes)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ServiceRadarWebNGWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
