defmodule ServiceRadar.Application do
  @moduledoc """
  ServiceRadar Core Application.

  Starts the core supervision tree including:
  - Database connection pool (Repo)
  - Oban job processor
  - Cluster supervisor (libcluster + Horde)
  - Poller and Agent registries

  This application can run standalone or as a dependency of
  serviceradar_web, serviceradar_poller, or serviceradar_agent.

  ## Configuration

  - `:repo_enabled` - Whether to start the database connection pool (default: true)
  - `:oban_enabled` - Whether to start Oban job processor (default: true)
  - `:cluster_enabled` - Whether to start cluster infrastructure (default: false)
  - `:registries_enabled` - Whether to start Horde registries (default: true)
  """
  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Encryption vault for AshCloak (must start before repo for encrypted field access)
        vault_child(),

        # Database (can be disabled for standalone tests)
        repo_child(),

        # PubSub for cluster events (always needed)
        {Phoenix.PubSub, name: ServiceRadar.PubSub},

        # Oban job processor (can be disabled for standalone tests)
        oban_child(),

        # Horde registries (always started for registration support)
        registry_children(),

        # SPIFFE certificate expiry monitoring
        cert_monitor_child(),

        # Cluster infrastructure (only if clustering is enabled)
        cluster_children()
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :one_for_one, name: ServiceRadar.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp vault_child do
    if Application.get_env(:serviceradar_core, :vault_enabled, true) do
      ServiceRadar.Vault
    else
      nil
    end
  end

  defp repo_child do
    if Application.get_env(:serviceradar_core, :repo_enabled, true) do
      ServiceRadar.Repo
    else
      nil
    end
  end

  defp oban_child do
    case Application.get_env(:serviceradar_core, Oban) do
      false -> nil
      nil -> nil
      oban_config when is_list(oban_config) -> {Oban, oban_config}
    end
  end

  defp registry_children do
    if Application.get_env(:serviceradar_core, :registries_enabled, true) do
      [
        # Horde distributed registries for pollers and agents
        ServiceRadar.PollerRegistry,
        ServiceRadar.AgentRegistry
      ]
    else
      []
    end
  end

  defp cluster_children do
    if Application.get_env(:serviceradar_core, :cluster_enabled, false) do
      [
        # Cluster supervisor manages libcluster + Horde
        ServiceRadar.ClusterSupervisor,
        ServiceRadar.ClusterHealth
      ]
    else
      []
    end
  end

  defp cert_monitor_child do
    enabled =
      case System.get_env("SPIFFE_CERT_MONITOR_ENABLED") do
        nil -> Application.get_env(:serviceradar_core, :spiffe_cert_monitor_enabled, true)
        value -> value in ~w(true 1 yes)
      end

    if enabled and ServiceRadar.SPIFFE.certs_available?() do
      ServiceRadar.SPIFFE.CertMonitor
    else
      nil
    end
  end
end
