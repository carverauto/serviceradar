defmodule ServiceRadarCoreElx.Application do
  @moduledoc """
  ServiceRadar Core-ELX Application.

  This is the primary coordination node for the ServiceRadar cluster.
  It configures serviceradar_core with cluster-specific settings but does NOT
  start duplicate processes - serviceradar_core handles all child processes.

  ## Responsibilities

  - Enable cluster mode for serviceradar_core
  - Enable AshOban scheduler (only core-elx runs schedulers)
  - Configure runtime settings before serviceradar_core starts

  ## Architecture

  Core-ELX is a thin wrapper that:
  1. Sets cluster_enabled = true (enables ClusterSupervisor, ClusterHealth in serviceradar_core)
  2. Sets start_ash_oban_scheduler = true (enables AshOban schedulers)
  3. Starts any core-elx specific services (none currently)

  All distributed registry, supervision, and clustering is handled by
  serviceradar_core's Application module when cluster_enabled is true.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting ServiceRadar Core-ELX node: #{node()}")

    # Core-ELX doesn't start duplicate children - serviceradar_core handles everything
    # when cluster_enabled=true is set in runtime.exs
    #
    # The following are started by serviceradar_core when cluster_enabled=true:
    # - ServiceRadar.ClusterSupervisor (libcluster + Horde)
    # - ServiceRadar.ClusterHealth
    # - TenantRegistry (for per-tenant registries)
    #
    # AshOban scheduler is started when :start_ash_oban_scheduler = true

    children = []

    Logger.info("Core-ELX initialized - serviceradar_core handles cluster infrastructure")

    opts = [strategy: :one_for_one, name: ServiceRadarCoreElx.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
