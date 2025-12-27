defmodule ServiceRadarCoreElx.Application do
  @moduledoc """
  ServiceRadar Core-ELX Application.

  This is the primary coordination node for the ServiceRadar cluster.
  It owns the Horde supervisors and registries, and other nodes
  connect to it for distributed process coordination.

  ## Responsibilities

  - Cluster formation (libcluster)
  - Distributed process supervision (Horde.DynamicSupervisor)
  - Distributed registry (Horde.Registry via PollerRegistry/AgentRegistry)
  - Cluster health monitoring
  - AshOban job scheduling

  ## Architecture

  Core-ELX runs the "primary" cluster coordination. Web-NG and Poller-ELX
  nodes connect to Core-ELX to participate in the distributed registry
  and supervision tree.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting ServiceRadar Core-ELX node: #{node()}")

    cluster_enabled = Application.get_env(:serviceradar_core, :cluster_enabled, true)
    registries_enabled = Application.get_env(:serviceradar_core, :registries_enabled, true)

    children =
      []
      |> maybe_add_cluster_supervisor(cluster_enabled)
      |> maybe_add_cluster_health(cluster_enabled)
      |> maybe_add_poller_supervisor(registries_enabled)
      |> maybe_add_registries(registries_enabled)

    Logger.info("Core-ELX starting #{length(children)} services (cluster=#{cluster_enabled}, registries=#{registries_enabled})")

    opts = [strategy: :one_for_one, name: ServiceRadarCoreElx.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_cluster_supervisor(children, true) do
    children ++ [{ServiceRadar.ClusterSupervisor, []}]
  end

  defp maybe_add_cluster_supervisor(children, false), do: children

  defp maybe_add_cluster_health(children, true) do
    children ++ [{ServiceRadar.ClusterHealth, []}]
  end

  defp maybe_add_cluster_health(children, false), do: children

  defp maybe_add_poller_supervisor(children, true) do
    children ++ [{ServiceRadar.PollerSupervisor, []}]
  end

  defp maybe_add_poller_supervisor(children, false), do: children

  defp maybe_add_registries(children, true) do
    children ++
      [
        {ServiceRadar.PollerRegistry, []},
        {ServiceRadar.AgentRegistry, []}
      ]
  end

  defp maybe_add_registries(children, false), do: children
end
