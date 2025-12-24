defmodule ServiceRadarPoller.Application do
  @moduledoc """
  ServiceRadar Poller Application.

  This is a standalone Elixir release that runs on edge infrastructure
  (bare metal, Docker, or Kubernetes) and joins the ServiceRadar ERTS cluster.

  The poller is responsible for:
  - Joining the distributed ERTS cluster via mTLS
  - Registering itself in the Horde distributed registry
  - Forwarding monitoring data to the core cluster
  - Executing polling tasks assigned by the core via ERTS messaging

  ## Environment Variables

  - `POLLER_PARTITION_ID` - The partition this poller belongs to
  - `POLLER_ID` - Unique identifier for this poller
  - `POLLER_DOMAIN` - The domain this poller monitors
  - `POLLER_CAPABILITIES` - Comma-separated list of capabilities (e.g., "icmp,tcp,http")
  - `CLUSTER_HOSTS` - Comma-separated list of cluster nodes to join

  ## Architecture

  ```
  ┌─────────────────────────────────────────────────────────┐
  │                    ServiceRadar Core                     │
  │  ┌─────────────┐  ┌──────────────┐  ┌───────────────┐   │
  │  │ Horde       │  │ libcluster   │  │ Task          │   │
  │  │ Registry    │  │              │  │ Orchestrator  │   │
  │  └──────┬──────┘  └──────┬───────┘  └───────┬───────┘   │
  └─────────┼────────────────┼──────────────────┼───────────┘
            │ mTLS/ERTS      │                  │
            │                │                  │
  ┌─────────┼────────────────┼──────────────────┼───────────┐
  │         ▼                ▼                  ▼           │
  │  ┌─────────────┐  ┌──────────────┐  ┌───────────────┐   │
  │  │ Registration│  │ Cluster      │  │ Task          │   │
  │  │ Worker      │  │ Membership   │  │ Executor      │   │
  │  └─────────────┘  └──────────────┘  └───────────────┘   │
  │                    ServiceRadar Poller                   │
  └──────────────────────────────────────────────────────────┘
  ```

  Communication happens via Erlang distributed messaging (ERTS).
  The poller joins the cluster via libcluster and uses Horde for
  distributed registry and process management.
  """

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    partition_id = System.get_env("POLLER_PARTITION_ID", "default")
    poller_id = System.get_env("POLLER_ID", generate_poller_id())
    domain = System.get_env("POLLER_DOMAIN", "default")

    capabilities = parse_capabilities(System.get_env("POLLER_CAPABILITIES", ""))

    Logger.info("Starting ServiceRadar Poller: #{poller_id} in partition: #{partition_id}")

    children = [
      # Poller-specific configuration store
      {ServiceRadarPoller.Config,
       partition_id: partition_id,
       poller_id: poller_id,
       domain: domain,
       capabilities: capabilities},

      # Registration worker - registers this poller in the distributed registry
      {ServiceRadar.Poller.RegistrationWorker,
       partition_id: partition_id,
       poller_id: poller_id,
       domain: domain,
       capabilities: capabilities},

      # Task executor - executes polling tasks from the core
      ServiceRadarPoller.TaskExecutor
    ]

    opts = [strategy: :one_for_one, name: ServiceRadarPoller.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp parse_capabilities(capabilities_str) do
    capabilities_str
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_atom/1)
  end

  defp generate_poller_id do
    hostname =
      case :inet.gethostname() do
        {:ok, name} -> List.to_string(name)
        _ -> "unknown"
      end

    "poller-#{hostname}-#{:rand.uniform(9999)}"
  end
end
